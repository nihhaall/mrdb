import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mrdb/services/network_service.dart';

enum StreamConnectionPhase {
  initializing,
  streaming,
  direct,
  retrying,
  offline,
}

@immutable
class StreamNetworkStats {
  final StreamConnectionPhase phase;
  final double bytesPerSecond;
  final int bufferedCacheBytes;
  final int totalBytes;
  final String transportLabel;
  final int? lastHttpErrorStatus;

  const StreamNetworkStats({
    this.phase = StreamConnectionPhase.initializing,
    this.bytesPerSecond = 0,
    this.bufferedCacheBytes = 0,
    this.totalBytes = 0,
    this.transportLabel = '',
    this.lastHttpErrorStatus,
  });

  StreamNetworkStats copyWith({
    StreamConnectionPhase? phase,
    double? bytesPerSecond,
    int? bufferedCacheBytes,
    int? totalBytes,
    String? transportLabel,
    int? lastHttpErrorStatus,
    bool clearErrorStatus = false,
  }) {
    return StreamNetworkStats(
      phase: phase ?? this.phase,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      bufferedCacheBytes: bufferedCacheBytes ?? this.bufferedCacheBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      transportLabel: transportLabel ?? this.transportLabel,
      lastHttpErrorStatus: clearErrorStatus
          ? null
          : (lastHttpErrorStatus ?? this.lastHttpErrorStatus),
    );
  }

  String formattedSpeed() {
    final bps = math.max(0.0, bytesPerSecond);
    final kbps = bps / 1024;
    if (kbps < 1024) {
      return '${kbps.round()} KB/s';
    }
    return '${(kbps / 1024).toStringAsFixed(2)} MB/s';
  }

  String formattedMbps() {
    final mbps = math.max(0.0, bytesPerSecond) / (1024 * 1024);
    return '${mbps.toStringAsFixed(2)} MB/s';
  }
}

/// Progressive loopback streaming proxy for `MkvStreamPlayerPage`.
///
/// Binds immediately (zero upfront probe round-trip), reuses persistent HTTP/1.1
/// keep-alive sockets (`HttpClient`), yields incoming TCP packets immediately
/// without blocking for whole 1 MiB chunks, keeps a bounded 16 MiB ring cache
/// of aligned chunks for instant rewind (`-10s`), auto-reconnects mid-stream at
/// the exact byte offset on socket drops, and emits live `MB/s` telemetry.
class StreamProxyService {
  static const int defaultChunkSize = 1024 * 1024;
  static const int defaultMaxCachedChunks = 24;
  static const int defaultMaxDiskCachedChunks = 512;

  final int chunkSize;
  final int maxCachedChunks;
  final int maxDiskCachedChunks;
  final bool enableDiskCache;

  final ValueNotifier<StreamNetworkStats> stats =
      ValueNotifier<StreamNetworkStats>(const StreamNetworkStats());

  HttpServer? _server;
  HttpClient? _httpClient;
  Uri? _upstreamUri;
  int _totalBytes = 0;
  bool _supportsRanges = false;
  String _contentType = 'video/x-matroska';
  int _focusChunk = 0;
  bool _disposed = false;

  final LinkedHashMap<int, Uint8List> _ringCache =
      LinkedHashMap<int, Uint8List>();
  final LinkedHashSet<int> _diskCachedChunks = LinkedHashSet<int>();
  final Map<int, Future<void>> _pendingDiskWrites = {};
  Directory? _diskCacheDir;
  final List<({DateTime time, int bytes})> _speedSamples = [];
  Timer? _telemetryTimer;

  StreamProxyService({
    this.chunkSize = defaultChunkSize,
    this.maxCachedChunks = defaultMaxCachedChunks,
    this.maxDiskCachedChunks = defaultMaxDiskCachedChunks,
    this.enableDiskCache = true,
  });

  bool get isRunning => _server != null && !_disposed;

  void setTransportLabel(String label) {
    if (_disposed) return;
    final clean = label.trim();
    final isOffline = clean.toLowerCase() == 'offline';
    stats.value = stats.value.copyWith(
      transportLabel: clean,
      phase: isOffline
          ? StreamConnectionPhase.offline
          : (stats.value.phase == StreamConnectionPhase.offline
              ? (_server != null
                  ? StreamConnectionPhase.streaming
                  : StreamConnectionPhase.direct)
              : stats.value.phase),
    );
  }

  /// Normalizes FileToLinkBot `/<msg_id>/<name>?hash=<hash>` URLs to `/<hash><msg_id>`
  /// so CDN proxies (e.g. Cloudflare) treat byte-range seeks as dynamic rather
  /// than triggering background full-file `.mkv` cache fills.
  static Uri normalizeUpstreamUri(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return uri;
    final first = segments.first.toLowerCase();
    if (first == 'transcode' || first == 'watch' || first == 'api') {
      return uri;
    }
    if (!RegExp(r'^\d+$').hasMatch(segments.first)) return uri;
    final hash = uri.queryParameters['hash']?.trim() ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{6}$').hasMatch(hash)) return uri;

    final keptQuery = Map<String, String>.from(uri.queryParameters)
      ..remove('hash');
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/$hash${segments.first}',
      queryParameters: keptQuery.isEmpty ? null : keptQuery,
    );
  }

  /// Immediately binds a loopback HTTP server and returns `http://127.0.0.1:<port>/stream`.
  /// Falls back to [upstreamUrl] only if the URL is non-HTTP or loopback bind fails.
  Future<String> start(String upstreamUrl) async {
    await stop();
    if (_disposed) return upstreamUrl;

    final parsed = Uri.tryParse(upstreamUrl.trim());
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return upstreamUrl;
    }

    _httpClient = runZoned(
      () => HttpClient()
        ..maxConnectionsPerHost = 6
        ..connectionTimeout = const Duration(seconds: 12)
        ..idleTimeout = const Duration(seconds: 20),
      zoneValues: const {NetworkService.playerStreamZoneKey: true},
    );
    _upstreamUri = normalizeUpstreamUri(parsed);

    if (enableDiskCache && maxDiskCachedChunks > 0) {
      unawaited(_cleanupStaleTempDirs());
      try {
        _diskCacheDir = await Directory.systemTemp.createTemp(
          'mrdb_stream_cache_',
        );
      } catch (_) {
        _diskCacheDir = null;
      }
    }

    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (_disposed) {
        await server.close(force: true);
        return upstreamUrl;
      }
      _server = server;
      server.listen(
        _handleRequest,
        onError: (_) {},
        cancelOnError: false,
      );
      _telemetryTimer = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => _publishTelemetry(),
      );
      stats.value = stats.value.copyWith(
        phase: StreamConnectionPhase.streaming,
        bytesPerSecond: 0,
        bufferedCacheBytes: 0,
        totalBytes: 0,
        clearErrorStatus: true,
      );
      return 'http://127.0.0.1:${server.port}/stream';
    } catch (_) {
      _httpClient?.close(force: true);
      _httpClient = null;
      stats.value = stats.value.copyWith(phase: StreamConnectionPhase.direct);
      return upstreamUrl;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (_disposed || _upstreamUri == null || _httpClient == null) {
        response.statusCode = HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }

      if (request.uri.path != '/stream') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final isHead = request.method.toUpperCase() == 'HEAD';

      if (isHead) {
        await _handleHead(response, rangeHeader);
        return;
      }

      response.bufferOutput = false;
      final parsedRange = _parseRange(rangeHeader);
      final reqStart = parsedRange?.start ?? 0;
      final explicitEnd = parsedRange?.end;
      final isSmallProbe = explicitEnd != null &&
          (explicitEnd - reqStart + 1) <= chunkSize ~/ 2;

      // Serve immediately from RAM cache if we already know total length and
      // the starting chunk is cached.
      if (_supportsRanges && _totalBytes > 0) {
        if (reqStart < 0 || reqStart >= _totalBytes) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$_totalBytes',
          );
          await response.close();
          return;
        }
        final resolvedEnd = explicitEnd != null
            ? math.min(explicitEnd, _totalBytes - 1)
            : _totalBytes - 1;
        if (resolvedEnd < reqStart) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$_totalBytes',
          );
          await response.close();
          return;
        }

        final firstChunkIdx = reqStart ~/ chunkSize;
        if (_hasCachedChunk(firstChunkIdx)) {
          _writeStreamHeaders(
            response,
            hasRange: rangeHeader != null,
            start: reqStart,
            end: resolvedEnd,
            totalBytes: _totalBytes,
            supportsRanges: true,
            contentType: _contentType,
          );
          await response.addStream(
            _streamProgressive(
              reqStart,
              resolvedEnd,
              initialResponse: null,
            ),
          );
          await response.close();
          return;
        }
      }

      // Open upstream connection immediately (0 extra probe round-trip).
      final opened = await _openUpstreamResponse(
        start: reqStart,
        end: isSmallProbe ? explicitEnd : explicitEnd,
        sendRangeHeader: rangeHeader != null || _supportsRanges,
      );
      if (opened == null) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }

      final upResp = opened.response;
      if (upResp.statusCode >= 400) {
        final code = upResp.statusCode;
        await upResp.drain<void>();
        stats.value = stats.value.copyWith(lastHttpErrorStatus: code);
        response.statusCode = code;
        await response.close();
        return;
      }

      _updateMetadataFromResponse(upResp, fallbackStart: reqStart);

      final isPartial = upResp.statusCode == HttpStatus.partialContent;
      final streamStart = isPartial ? reqStart : 0;
      int? streamEnd;
      if (_totalBytes > 0) {
        streamEnd = explicitEnd != null
            ? math.min(explicitEnd, _totalBytes - 1)
            : _totalBytes - 1;
      } else if (upResp.contentLength > 0 && isPartial == false) {
        streamEnd = streamStart + upResp.contentLength - 1;
      }

      _writeStreamHeaders(
        response,
        hasRange: isPartial,
        start: streamStart,
        end: streamEnd,
        totalBytes: _totalBytes > 0 ? _totalBytes : null,
        supportsRanges: _supportsRanges,
        contentType: _contentType,
      );

      await response.addStream(
        _streamProgressive(
          streamStart,
          streamEnd,
          initialResponse: upResp,
        ),
      );
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleHead(HttpResponse response, String? rangeHeader) async {
    final client = _httpClient;
    final uri = _upstreamUri;
    if (client == null || uri == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    HttpClientRequest? req;
    try {
      req = await client.headUrl(uri).timeout(const Duration(seconds: 15));
      req.followRedirects = true;
      req.headers.set(HttpHeaders.userAgentHeader, 'MRDb/1.0');
      req.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
      if (rangeHeader != null) {
        req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain<void>();

      if (resp.statusCode >= 400) {
        stats.value = stats.value.copyWith(lastHttpErrorStatus: resp.statusCode);
        response.statusCode = resp.statusCode;
        await response.close();
        return;
      }

      _updateMetadataFromResponse(resp, fallbackStart: 0);
      response.statusCode = resp.statusCode;
      response.headers.set(HttpHeaders.contentTypeHeader, _contentType);
      response.headers.set(
        HttpHeaders.acceptRangesHeader,
        _supportsRanges ? 'bytes' : 'none',
      );
      if (resp.contentLength > 0) {
        response.headers.contentLength = resp.contentLength;
      } else if (_totalBytes > 0) {
        response.headers.contentLength = _totalBytes;
      }
      await response.close();
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
      response.statusCode = HttpStatus.badGateway;
      await response.close();
    }
  }

  ({int start, int? end})? _parseRange(String? rangeHeader) {
    if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) return null;
    final spec = rangeHeader.substring(6).split(',').first.trim();
    final parts = spec.split('-');
    final sStr = parts.isNotEmpty ? parts[0].trim() : '';
    final eStr = parts.length > 1 ? parts[1].trim() : '';
    if (sStr.isEmpty && eStr.isNotEmpty && _totalBytes > 0) {
      final suffix = int.tryParse(eStr) ?? 0;
      return (start: math.max(0, _totalBytes - suffix), end: _totalBytes - 1);
    }
    final s = int.tryParse(sStr) ?? 0;
    final e = eStr.isNotEmpty ? int.tryParse(eStr) : null;
    return (start: s, end: e);
  }

  void _updateMetadataFromResponse(
    HttpClientResponse resp, {
    required int fallbackStart,
  }) {
    final mime = resp.headers.contentType?.mimeType;
    if (mime != null && mime.isNotEmpty) {
      _contentType = mime;
    }
    final acceptRanges =
        (resp.headers.value(HttpHeaders.acceptRangesHeader) ?? '').toLowerCase();
    final contentRange =
        resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    if (resp.statusCode == HttpStatus.partialContent && contentRange.isNotEmpty) {
      _supportsRanges = true;
      final slashIdx = contentRange.lastIndexOf('/');
      if (slashIdx != -1) {
        final total = int.tryParse(contentRange.substring(slashIdx + 1).trim());
        if (total != null && total > 0) {
          _totalBytes = total;
        }
      }
    } else if (acceptRanges == 'bytes') {
      _supportsRanges = true;
      if (fallbackStart == 0 && resp.contentLength > 0) {
        _totalBytes = resp.contentLength;
      }
    } else if (acceptRanges == 'none') {
      _supportsRanges = false;
      _totalBytes = resp.contentLength > 0 ? resp.contentLength : 0;
    } else if (fallbackStart == 0 && resp.contentLength > 0) {
      _totalBytes = resp.contentLength;
    }

    stats.value = stats.value.copyWith(
      totalBytes: _totalBytes,
      clearErrorStatus: true,
    );
  }

  void _writeStreamHeaders(
    HttpResponse response, {
    required bool hasRange,
    required int start,
    required int? end,
    required int? totalBytes,
    required bool supportsRanges,
    required String contentType,
  }) {
    response.statusCode =
        hasRange ? HttpStatus.partialContent : HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    response.headers.set(
      HttpHeaders.acceptRangesHeader,
      supportsRanges ? 'bytes' : 'none',
    );
    if (hasRange && end != null && totalBytes != null && totalBytes > 0) {
      response.headers.contentLength = end - start + 1;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$totalBytes',
      );
    } else if (!hasRange && end != null && start == 0) {
      response.headers.contentLength = end + 1;
    } else if (totalBytes != null && totalBytes > 0 && !hasRange && start == 0) {
      response.headers.contentLength = totalBytes;
    }
  }

  Future<({HttpClientResponse response, HttpClientRequest request})?>
      _openUpstreamResponse({
    required int start,
    required int? end,
    required bool sendRangeHeader,
  }) async {
    final client = _httpClient;
    final uri = _upstreamUri;
    if (client == null || uri == null || _disposed) return null;

    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts && !_disposed; attempt++) {
      HttpClientRequest? req;
      try {
        req = await client.getUrl(uri).timeout(const Duration(seconds: 12));
        req.followRedirects = true;
        req.headers.set(HttpHeaders.userAgentHeader, 'MRDb/1.0');
        req.headers.set(
          HttpHeaders.connectionHeader,
          attempt > 0 ? 'close' : 'keep-alive',
        );
        if (sendRangeHeader && (start > 0 || end != null)) {
          final endStr = end != null ? '$end' : '';
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endStr');
        } else if (sendRangeHeader) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        }
        final resp = await req.close().timeout(const Duration(seconds: 18));
        if (resp.statusCode >= 500 && attempt < maxAttempts - 1) {
          await resp.drain<void>();
          if (!_disposed) {
            stats.value = stats.value.copyWith(
              phase: StreamConnectionPhase.retrying,
            );
          }
          await Future<void>.delayed(
            Duration(milliseconds: 250 * (attempt + 1)),
          );
          continue;
        }
        return (response: resp, request: req);
      } catch (_) {
        try {
          req?.abort();
        } catch (_) {}
        if (attempt < maxAttempts - 1 && !_disposed) {
          stats.value = stats.value.copyWith(
            phase: StreamConnectionPhase.retrying,
          );
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (attempt + 1)),
          );
        }
      }
    }
    return null;
  }

  Stream<List<int>> _streamProgressive(
    int start,
    int? end, {
    required HttpClientResponse? initialResponse,
  }) async* {
    var cursor = start;
    HttpClientResponse? currentResp = initialResponse;
    var reconnectCount = 0;
    const maxMidStreamReconnects = 4;

    while (!_disposed && (end == null || cursor <= end)) {
      if (_supportsRanges && _totalBytes > 0) {
        final chunkIdx = cursor ~/ chunkSize;
        _focusChunk = chunkIdx;
        final cached = await _getCachedChunk(chunkIdx);
        if (cached != null) {
          // Discard any open upstream stream if we jumped inside cached RAM.
          if (currentResp != null) {
            unawaited(
              currentResp
                  .detachSocket()
                  .then((socket) => socket.destroy())
                  .catchError((_) {}),
            );
            currentResp = null;
          }
          final chunkBase = chunkIdx * chunkSize;
          final sliceStart = cursor - chunkBase;
          if (sliceStart < cached.length) {
            final maxRemaining = end != null
                ? math.min(end - cursor + 1, cached.length - sliceStart)
                : cached.length - sliceStart;
            if (maxRemaining > 0) {
              yield sliceStart == 0 && maxRemaining == cached.length
                  ? cached
                  : Uint8List.sublistView(
                      cached,
                      sliceStart,
                      sliceStart + maxRemaining,
                    );
              cursor += maxRemaining;
              continue;
            }
          }
        }
      }

      if (currentResp == null) {
        final opened = await _openUpstreamResponse(
          start: cursor,
          end: end,
          sendRangeHeader: _supportsRanges,
        );
        if (opened == null) break;
        currentResp = opened.response;
        if (currentResp.statusCode >= 400) {
          await currentResp.drain<void>();
          currentResp = null;
          break;
        }
      }

      if (!_disposed && stats.value.phase == StreamConnectionPhase.retrying) {
        stats.value = stats.value.copyWith(
          phase: StreamConnectionPhase.streaming,
        );
      }

      var chunkBuilder = _supportsRanges ? BytesBuilder(copy: false) : null;
      var currentChunkIdx = cursor ~/ chunkSize;
      var nextChunkBoundary = (currentChunkIdx + 1) * chunkSize;
      // Only cache blocks starting cleanly on a chunk boundary.
      var buildingAligned = _supportsRanges && (cursor % chunkSize == 0);
      if (!buildingAligned) {
        chunkBuilder = null;
      }

      var streamErrored = false;
      var completedCleanly = false;
      final pendingResp = currentResp;
      currentResp = null;
      try {
        await for (final packet
            in pendingResp.timeout(const Duration(seconds: 25))) {
          if (_disposed) break;
          if (packet.isEmpty) continue;

          _recordBandwidth(packet.length);

          var toEmit = packet;
          if (end != null) {
            final remaining = end - cursor + 1;
            if (remaining <= 0) break;
            if (toEmit.length > remaining) {
              toEmit = toEmit.sublist(0, remaining);
            }
          }

          // Feed packet immediately to mpv with ZERO chunk blocking.
          yield toEmit;

          if (_supportsRanges) {
            _focusChunk = cursor ~/ chunkSize;
            var pOffset = 0;
            while (pOffset < toEmit.length) {
              final absPos = cursor + pOffset;
              final idx = absPos ~/ chunkSize;
              if (idx != currentChunkIdx) {
                currentChunkIdx = idx;
                nextChunkBoundary = (idx + 1) * chunkSize;
                buildingAligned = (absPos % chunkSize == 0);
                chunkBuilder = buildingAligned ? BytesBuilder(copy: false) : null;
              }
              final untilBoundary = math.min(
                toEmit.length - pOffset,
                nextChunkBoundary - absPos,
              );
              if (buildingAligned && chunkBuilder != null) {
                chunkBuilder.add(
                  toEmit is Uint8List
                      ? Uint8List.sublistView(
                          toEmit,
                          pOffset,
                          pOffset + untilBoundary,
                        )
                      : toEmit.sublist(pOffset, pOffset + untilBoundary),
                );
                if (absPos + untilBoundary == nextChunkBoundary ||
                    (_totalBytes > 0 && absPos + untilBoundary == _totalBytes)) {
                  _storeCacheChunk(currentChunkIdx, chunkBuilder.takeBytes());
                  chunkBuilder = null;
                  buildingAligned = false;
                }
              }
              pOffset += untilBoundary;
            }
          }

          cursor += toEmit.length;
          reconnectCount = 0;
          if (end != null && cursor > end) {
            completedCleanly = true;
            break;
          }
        }
        if (!_disposed &&
            (!_supportsRanges ||
                end == null ||
                cursor > end ||
                (_totalBytes > 0 && cursor >= _totalBytes))) {
          completedCleanly = true;
        }
      } catch (_) {
        streamErrored = true;
      } finally {
        if (!completedCleanly) {
          unawaited(
            pendingResp
                .detachSocket()
                .then((socket) => socket.destroy())
                .catchError((_) {}),
          );
        }
      }

      if (_disposed) break;
      if (!_supportsRanges) break;
      if (end != null && cursor > end) break;
      if (_totalBytes > 0 && cursor >= _totalBytes) break;

      // Retry seamlessly from exact cursor if network hiccuped mid-stream.
      if (streamErrored || (end == null && _totalBytes > 0 && cursor < _totalBytes)) {
        if (reconnectCount >= maxMidStreamReconnects) break;
        reconnectCount++;
        stats.value = stats.value.copyWith(phase: StreamConnectionPhase.retrying);
        await Future<void>.delayed(Duration(milliseconds: 250 * reconnectCount));
        continue;
      }
      break;
    }
  }

  bool _hasCachedChunk(int chunkIdx) {
    return _ringCache.containsKey(chunkIdx) ||
        _diskCachedChunks.contains(chunkIdx);
  }

  Uint8List? _touchCacheChunk(int chunkIdx) {
    final hit = _ringCache.remove(chunkIdx);
    if (hit != null) {
      _ringCache[chunkIdx] = hit;
    }
    return hit;
  }

  Future<Uint8List?> _getCachedChunk(int chunkIdx) async {
    final ramHit = _touchCacheChunk(chunkIdx);
    if (ramHit != null) return ramHit;

    if (!_diskCachedChunks.contains(chunkIdx)) return null;
    final dir = _diskCacheDir;
    if (dir == null) {
      _diskCachedChunks.remove(chunkIdx);
      return null;
    }

    final pending = _pendingDiskWrites[chunkIdx];
    if (pending != null) {
      await pending;
    }
    if (_disposed || _diskCacheDir != dir) return null;

    try {
      final file = File('${dir.path}${Platform.pathSeparator}c_$chunkIdx.bin');
      if (!await file.exists()) {
        _diskCachedChunks.remove(chunkIdx);
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _diskCachedChunks.remove(chunkIdx);
        return null;
      }
      _diskCachedChunks.remove(chunkIdx);
      _diskCachedChunks.add(chunkIdx);
      _insertRamChunk(chunkIdx, bytes);
      return bytes;
    } catch (_) {
      _diskCachedChunks.remove(chunkIdx);
      return null;
    }
  }

  void _insertRamChunk(int chunkIdx, Uint8List data) {
    _ringCache.remove(chunkIdx);
    _ringCache[chunkIdx] = data;

    while (_ringCache.length > maxCachedChunks) {
      int? victim;
      var worstDist = -1;
      for (final key in _ringCache.keys) {
        if (key < _focusChunk - 4) {
          final d = _focusChunk - key;
          if (d > worstDist) {
            worstDist = d;
            victim = key;
          }
        }
      }
      victim ??= _ringCache.keys.first;
      _ringCache.remove(victim);
    }
  }

  void _storeCacheChunk(int chunkIdx, Uint8List data) {
    if (data.isEmpty) return;
    _insertRamChunk(chunkIdx, data);
    _persistDiskChunk(chunkIdx, data);
  }

  void _persistDiskChunk(int chunkIdx, Uint8List data) {
    if (!enableDiskCache || maxDiskCachedChunks <= 0 || _disposed) return;
    final dir = _diskCacheDir;
    if (dir == null) return;

    _diskCachedChunks.remove(chunkIdx);
    _diskCachedChunks.add(chunkIdx);

    while (_diskCachedChunks.length > maxDiskCachedChunks) {
      final victim = _diskCachedChunks.first;
      _diskCachedChunks.remove(victim);
      unawaited(
        File('${dir.path}${Platform.pathSeparator}c_$victim.bin')
            .delete()
            .catchError((_) => File('')),
      );
    }

    final file = File('${dir.path}${Platform.pathSeparator}c_$chunkIdx.bin');
    final writeFuture = file
        .writeAsBytes(data, flush: false)
        .then<void>((_) {}, onError: (_) {
      _diskCachedChunks.remove(chunkIdx);
    }).whenComplete(() {
      _pendingDiskWrites.remove(chunkIdx);
    });
    _pendingDiskWrites[chunkIdx] = writeFuture;
  }

  Future<void> _cleanupStaleTempDirs() async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 4));
      await for (final entity in Directory.systemTemp.list(followLinks: false)) {
        if (entity is Directory &&
            entity.path.contains('mrdb_stream_cache_') &&
            entity.path != _diskCacheDir?.path) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _recordBandwidth(int bytes) {
    if (bytes <= 0) return;
    _speedSamples.add((time: DateTime.now(), bytes: bytes));
  }

  void _publishTelemetry() {
    if (_disposed) return;
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(milliseconds: 1500));
    _speedSamples.removeWhere((s) => s.time.isBefore(cutoff));

    double bytesPerSec = 0;
    if (_speedSamples.isNotEmpty) {
      final total = _speedSamples.fold<int>(0, (sum, s) => sum + s.bytes);
      final elapsedMs = now.difference(_speedSamples.first.time).inMilliseconds;
      // Avoid ramping up from 0/1 KB/s during the very first <150ms burst.
      if (elapsedMs >= 150) {
        bytesPerSec = total / (elapsedMs / 1000.0);
      } else if (stats.value.bytesPerSecond > 0) {
        bytesPerSec = stats.value.bytesPerSecond;
      }
    }

    var cacheBytes = 0;
    for (final v in _ringCache.values) {
      cacheBytes += v.length;
    }
    for (final idx in _diskCachedChunks) {
      if (!_ringCache.containsKey(idx)) {
        cacheBytes += chunkSize;
      }
    }

    stats.value = stats.value.copyWith(
      bytesPerSecond: bytesPerSec,
      bufferedCacheBytes: cacheBytes,
      totalBytes: _totalBytes,
    );
  }

  Future<void> stop() async {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _ringCache.clear();
    _diskCachedChunks.clear();
    final pendingWrites = _pendingDiskWrites.values.toList();
    _pendingDiskWrites.clear();
    if (pendingWrites.isNotEmpty) {
      await Future.wait(pendingWrites).catchError((_) => <void>[]);
    }
    final cacheDir = _diskCacheDir;
    _diskCacheDir = null;
    if (cacheDir != null) {
      try {
        if (await cacheDir.exists()) {
          await cacheDir.delete(recursive: true);
        }
      } catch (_) {}
    }
    _speedSamples.clear();
    _totalBytes = 0;
    _supportsRanges = false;

    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }

    final client = _httpClient;
    _httpClient = null;
    if (client != null) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    stats.dispose();
  }
}
