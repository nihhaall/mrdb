import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Classifies why a network request failed so screens can show accurate UI.
enum NetworkFailureType {
  none,
  noInternet,
  slowOrTimeout,
  serverOrBlocked,
}

class TmdbFetchException implements Exception {
  final NetworkFailureType type;
  final String message;
  final int? statusCode;
  final Object? cause;

  const TmdbFetchException({
    required this.type,
    required this.message,
    this.statusCode,
    this.cause,
  });

  @override
  String toString() => 'TmdbFetchException($type): $message';
}

class _DnsCacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;

  const _DnsCacheEntry(this.addresses, this.expiresAt);

  bool get isValid => DateTime.now().isBefore(expiresAt);
}

/// Resolves hostnames via DNS-over-HTTPS (DoH) so carrier DNS blocking /
/// poisoning (common on mobile data for `api.themoviedb.org`) is bypassed
/// without requiring a VPN or system Private DNS change.
class _DohResolver {
  static const Set<String> dohDomains = {
    'api.themoviedb.org',
    'api.tmdb.org',
    'image.tmdb.org',
    'www.themoviedb.org',
  };

  final HttpClient Function() _rawHttpClientFactory;
  final Map<String, _DnsCacheEntry> _cache = {};
  final Map<String, Future<List<InternetAddress>>> _inFlight = {};

  _DohResolver(this._rawHttpClientFactory);

  static bool shouldUseDoh(String host) {
    final lower = host.toLowerCase();
    return dohDomains.contains(lower);
  }

  void invalidate(String host) {
    _cache.remove(host.toLowerCase());
  }

  Future<List<InternetAddress>> resolve(String host) {
    final key = host.toLowerCase();
    final cached = _cache[key];
    if (cached != null && cached.isValid) {
      return Future.value(cached.addresses);
    }

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _lookupWithFallback(key).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<List<InternetAddress>> _lookupWithFallback(String host) async {
    // Race IP-direct and hostname DoH endpoints so both dual-stack (poisoned DNS)
    // and IPv6-only mobile carriers resolve quickly.
    final endpoints = <Uri>[
      Uri.parse('https://1.1.1.1/dns-query?name=$host&type=A'),
      Uri.parse('https://8.8.8.8/resolve?name=$host&type=A'),
      Uri.parse('https://dns.google/resolve?name=$host&type=A'),
      Uri.parse('https://cloudflare-dns.com/dns-query?name=$host&type=A'),
    ];

    final completer = Completer<List<InternetAddress>>();
    int remaining = endpoints.length;

    for (final endpoint in endpoints) {
      _queryDohEndpoint(endpoint).then((ips) {
        if (ips.isNotEmpty && !completer.isCompleted) {
          _cache[host] = _DnsCacheEntry(
            ips,
            DateTime.now().add(const Duration(minutes: 5)),
          );
          completer.complete(ips);
        } else {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(const []);
          }
        }
      }).catchError((_) {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(const []);
        }
      });
    }

    final dohIps = await completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () => const [],
    );
    if (dohIps.isNotEmpty) return dohIps;

    // Fallback to system DNS if DoH is unreachable (e.g. strict captive portal)
    try {
      final sys = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 3));
      final valid = sys.where((addr) => !_isSuspiciousSinkhole(addr)).toList();
      if (valid.isNotEmpty) {
        _cache[host] = _DnsCacheEntry(
          valid,
          DateTime.now().add(const Duration(minutes: 2)),
        );
        return valid;
      }
      return sys;
    } catch (_) {
      return const [];
    }
  }

  Future<List<InternetAddress>> _queryDohEndpoint(Uri uri) async {
    final client = _rawHttpClientFactory()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return const [];
      }
      final body = await utf8.decoder.bind(res).join();
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) return const [];
      final answers = data['Answer'];
      if (answers is! List) return const [];

      final ips = <InternetAddress>[];
      for (final item in answers) {
        if (item is Map && item['type'] == 1 && item['data'] is String) {
          final parsed = InternetAddress.tryParse(item['data'] as String);
          if (parsed != null && !_isSuspiciousSinkhole(parsed)) {
            ips.add(parsed);
          }
        }
      }
      return ips;
    } finally {
      client.close(force: true);
    }
  }

  static bool _isSuspiciousSinkhole(InternetAddress addr) {
    if (addr.isLoopback) return true;
    final raw = addr.address;
    if (raw == '0.0.0.0' || raw == '::' || raw.startsWith('127.')) return true;
    return false;
  }
}

/// Global [HttpOverrides] so `http`, `dio`, and `CachedNetworkImage`
/// automatically resolve TMDB domains via DoH and use safe connect timeouts.
class AppHttpOverrides extends HttpOverrides {
  late final _DohResolver _doh = _DohResolver(() => super.createHttpClient(null));

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final isPlayerStreamClient =
        Zone.current[NetworkService.playerStreamZoneKey] == true;
    final client = super.createHttpClient(context);
    client.connectionTimeout = const Duration(seconds: 8);
    client.idleTimeout = const Duration(seconds: 15);
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final lowerHost = uri.host.toLowerCase();
      final isLoopback = lowerHost == '127.0.0.1' ||
          lowerHost == 'localhost' ||
          lowerHost == '::1';
      if (!isPlayerStreamClient &&
          !isLoopback &&
          NetworkService.instance.isPlayerExclusiveActive) {
        await NetworkService.instance.waitUntilPlayerExits();
      }

      if (proxyHost != null) {
        return Socket.startConnect(proxyHost, proxyPort ?? uri.port);
      }

      final isHttps = uri.isScheme('https');
      final port = uri.port == 0 ? (isHttps ? 443 : 80) : uri.port;
      final host = uri.host;

      if (!_DohResolver.shouldUseDoh(host)) {
        return isHttps
            ? SecureSocket.startConnect(host, port, context: context)
            : Socket.startConnect(host, port);
      }

      return _connectWithDoh(
        uri: uri,
        host: host,
        port: port,
        isHttps: isHttps,
        context: context,
      );
    };
    return client;
  }

  Future<ConnectionTask<Socket>> _connectWithDoh({
    required Uri uri,
    required String host,
    required int port,
    required bool isHttps,
    required SecurityContext? context,
  }) async {
    bool cancelled = false;
    ConnectionTask<Socket>? activeTcpTask;
    Socket? activeSocket;
    final completer = Completer<Socket>();

    () async {
      try {
        final ips = await _doh.resolve(host);
        if (cancelled) return;

        Socket? connected;
        Object? lastError;

        // Try DoH-resolved IPv4 addresses (up to 3) so stale/unreachable IPs fail over
        for (final ip in ips.take(3)) {
          if (cancelled) return;
          try {
            final task = await Socket.startConnect(ip, port);
            activeTcpTask = task;
            if (cancelled) {
              task.cancel();
              return;
            }
            final sock = await task.socket.timeout(const Duration(seconds: 4));
            if (cancelled) {
              sock.destroy();
              return;
            }
            connected = sock;
            break;
          } catch (e) {
            lastError = e;
          }
        }

        // Fallback to system DNS (handles IPv6-only NAT64 networks or DoH outage)
        if (connected == null && !cancelled) {
          try {
            final task = await Socket.startConnect(host, port);
            activeTcpTask = task;
            if (cancelled) {
              task.cancel();
              return;
            }
            final sock = await task.socket.timeout(const Duration(seconds: 5));
            if (cancelled) {
              sock.destroy();
              return;
            }
            connected = sock;
          } catch (e) {
            lastError = e;
          }
        }

        if (connected == null) {
          _doh.invalidate(host);
          if (!completer.isCompleted) {
            completer.completeError(
              lastError ?? SocketException('Unable to connect to $host'),
            );
          }
          return;
        }

        activeSocket = connected;

        if (isHttps) {
          // Keeps full TLS SNI & strict certificate validation for `host`
          final secure = await SecureSocket.secure(
            connected,
            host: host,
            context: context,
          ).timeout(const Duration(seconds: 5));
          if (cancelled) {
            secure.destroy();
            return;
          }
          completer.complete(secure);
        } else {
          completer.complete(connected);
        }
      } catch (e, st) {
        _doh.invalidate(host);
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      }
    }();

    return ConnectionTask.fromSocket(completer.future, () {
      cancelled = true;
      activeTcpTask?.cancel();
      activeSocket?.destroy();
      if (!completer.isCompleted) {
        completer.completeError(const SocketException('Connection cancelled'));
      }
    });
  }
}

/// Centralized, mobile-data-resilient networking client for TMDB and connectivity checks.
class NetworkService {
  NetworkService._();
  static final NetworkService instance = NetworkService._();

  static const Object playerStreamZoneKey = #mrdbPlayerStream;

  static const String _primaryTmdbHost = 'api.themoviedb.org';
  static const String _fallbackTmdbHost = 'api.tmdb.org';

  String _preferredTmdbHost = _primaryTmdbHost;
  http.Client? _sharedClient;
  int _playerExclusiveDepth = 0;
  Completer<void>? _exclusiveReleaseCompleter;

  bool? _cachedOnline;
  DateTime? _cachedOnlineAt;

  bool get isPlayerExclusiveActive => _playerExclusiveDepth > 0;

  void enterPlayerExclusiveMode() {
    _playerExclusiveDepth++;
    if (_playerExclusiveDepth == 1) {
      _exclusiveReleaseCompleter = Completer<void>();
    }
  }

  void exitPlayerExclusiveMode() {
    if (_playerExclusiveDepth <= 0) {
      _playerExclusiveDepth = 0;
      return;
    }
    _playerExclusiveDepth--;
    if (_playerExclusiveDepth == 0) {
      final completer = _exclusiveReleaseCompleter;
      _exclusiveReleaseCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> waitUntilPlayerExits() {
    final c = _exclusiveReleaseCompleter;
    if (!isPlayerExclusiveActive || c == null || c.isCompleted) {
      return Future.value();
    }
    return c.future;
  }

  http.Client get client => _sharedClient ??= IOClient(HttpClient());

  /// Fast, real connectivity probe (works accurately on Wi-Fi, mobile data,
  /// captive portals, and offline Airplane mode without extra native plugins).
  Future<bool> hasInternet({bool forceRefresh = false}) async {
    if (isPlayerExclusiveActive) {
      return _cachedOnline ?? true;
    }
    if (!forceRefresh &&
        _cachedOnline != null &&
        _cachedOnlineAt != null &&
        DateTime.now().difference(_cachedOnlineAt!) <
            const Duration(seconds: 3)) {
      return _cachedOnline!;
    }

    final probes = <({Object host, int port})>[
      (host: InternetAddress('1.1.1.1'), port: 443),
      (host: InternetAddress('8.8.8.8'), port: 53),
      (host: 'dns.google', port: 443),
      (host: 'one.one.one.one', port: 443),
    ];

    final completer = Completer<bool>();
    int remaining = probes.length;

    for (final probe in probes) {
      Socket.connect(
        probe.host,
        probe.port,
        timeout: const Duration(milliseconds: 2800),
      ).then((socket) {
        socket.destroy();
        if (!completer.isCompleted) {
          completer.complete(true);
        }
      }).catchError((_) {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(false);
        }
      });
    }

    final online = await completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => false,
    );

    _cachedOnline = online;
    _cachedOnlineAt = DateTime.now();
    return online;
  }

  /// Fetches JSON from TMDB with:
  /// - DoH DNS bypass (via [AppHttpOverrides])
  /// - Hedged host failover (`api.themoviedb.org` <-> `api.tmdb.org`)
  /// - Slow-internet notification callback
  /// - Accurate offline vs timeout vs blocked error classification
  Future<dynamic> getTmdbJson(
    String pathAndQuery, {
    Duration timeout = const Duration(seconds: 15),
    int maxAttempts = 2,
    VoidCallback? onSlowConnection,
  }) async {
    final normalizedPath =
        pathAndQuery.startsWith('/') ? pathAndQuery : '/$pathAndQuery';

    bool slowNotified = false;
    final slowTimer = Timer(const Duration(milliseconds: 3500), () {
      slowNotified = true;
      onSlowConnection?.call();
    });

    Object? lastError;

    try {
      for (int attempt = 0; attempt < maxAttempts; attempt++) {
        try {
          return await _hedgedTmdbGet(normalizedPath, timeout: timeout);
        } catch (e) {
          lastError = e;
          final online = await hasInternet(forceRefresh: attempt > 0);
          if (!online) {
            throw TmdbFetchException(
              type: NetworkFailureType.noInternet,
              message: 'No internet connection',
              cause: e,
            );
          }

          if (attempt < maxAttempts - 1) {
            if (!slowNotified) {
              slowNotified = true;
              onSlowConnection?.call();
            }
            await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }
      }

      throw await classifyError(lastError ?? Exception('Request failed'));
    } finally {
      slowTimer.cancel();
    }
  }

  /// Convenience wrapper when callers already constructed a `Uri`.
  Future<dynamic> getTmdbUriJson(
    Uri uri, {
    Duration timeout = const Duration(seconds: 15),
    int maxAttempts = 2,
    VoidCallback? onSlowConnection,
  }) {
    final pathAndQuery = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    return getTmdbJson(
      pathAndQuery,
      timeout: timeout,
      maxAttempts: maxAttempts,
      onSlowConnection: onSlowConnection,
    );
  }

  Future<dynamic> _hedgedTmdbGet(
    String pathAndQuery, {
    required Duration timeout,
  }) async {
    final primaryHost = _preferredTmdbHost;
    final secondaryHost = primaryHost == _primaryTmdbHost
        ? _fallbackTmdbHost
        : _primaryTmdbHost;

    final completer = Completer<dynamic>();
    bool secondaryStarted = false;
    int activeRequests = 1;
    Object? firstError;
    Timer? hedgeTimer;

    void launchRequest(String host) {
      final uri = Uri.parse('https://$host$pathAndQuery');
      client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(timeout)
          .then((response) {
        if (response.statusCode != 200) {
          throw TmdbFetchException(
            type: NetworkFailureType.serverOrBlocked,
            message: 'HTTP ${response.statusCode}',
            statusCode: response.statusCode,
          );
        }
        final decoded = jsonDecode(response.body);
        if (!completer.isCompleted) {
          _preferredTmdbHost = host;
          hedgeTimer?.cancel();
          completer.complete(decoded);
        }
      }).catchError((Object err) {
        firstError ??= err;
        activeRequests--;

        // If primary failed quickly, immediately kick off secondary host
        if (!secondaryStarted && !completer.isCompleted) {
          secondaryStarted = true;
          hedgeTimer?.cancel();
          activeRequests++;
          launchRequest(secondaryHost);
          return;
        }

        if (activeRequests <= 0 && !completer.isCompleted) {
          hedgeTimer?.cancel();
          completer.completeError(firstError ?? err);
        }
      });
    }

    // Hedge after 2.0s if the primary host appears stalled (e.g. silent DPI drop)
    hedgeTimer = Timer(const Duration(milliseconds: 2000), () {
      if (!secondaryStarted && !completer.isCompleted) {
        secondaryStarted = true;
        activeRequests++;
        launchRequest(secondaryHost);
      }
    });

    launchRequest(primaryHost);
    return completer.future;
  }

  /// Maps any network exception into a clear [TmdbFetchException].
  Future<TmdbFetchException> classifyError(Object error) async {
    if (error is TmdbFetchException) return error;

    final online = await hasInternet(forceRefresh: true);
    if (!online) {
      return TmdbFetchException(
        type: NetworkFailureType.noInternet,
        message: 'No internet connection. Please check Wi-Fi or mobile data.',
        cause: error,
      );
    }

    if (error is TimeoutException) {
      return TmdbFetchException(
        type: NetworkFailureType.slowOrTimeout,
        message: 'Connection is too slow and timed out. Please try again.',
        cause: error,
      );
    }

    if (error is SocketException ||
        error is HandshakeException ||
        error is http.ClientException) {
      return TmdbFetchException(
        type: NetworkFailureType.serverOrBlocked,
        message: 'Unable to reach movie server on this network.',
        cause: error,
      );
    }

    return TmdbFetchException(
      type: NetworkFailureType.serverOrBlocked,
      message: 'Failed to load data. Please try again.',
      cause: error,
    );
  }
}
