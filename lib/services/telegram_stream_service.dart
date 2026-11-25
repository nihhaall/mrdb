import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TelegramVideoItem {
  final int? msgId;
  final String hash;
  final String streamCode;
  final String title;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final int? tmdbId;
  final DateTime? createdAt;
  final String streamUrl;
  final String? watchUrl;

  const TelegramVideoItem({
    this.msgId,
    this.hash = '',
    this.streamCode = '',
    required this.title,
    required this.fileName,
    this.fileSize = 0,
    this.mimeType = 'video/x-matroska',
    this.tmdbId,
    this.createdAt,
    required this.streamUrl,
    this.watchUrl,
  });

  bool get isMkv =>
      fileName.toLowerCase().endsWith('.mkv') ||
      mimeType.toLowerCase().contains('matroska');

  String get formatBadge {
    final lower = fileName.toLowerCase();
    for (final ext in const ['.mkv', '.mp4', '.webm', '.mov', '.avi', '.m4v']) {
      if (lower.endsWith(ext)) return ext.substring(1).toUpperCase();
    }
    if (mimeType.toLowerCase().contains('matroska')) return 'MKV';
    if (mimeType.toLowerCase().contains('mp4')) return 'MP4';
    return 'VIDEO';
  }

  factory TelegramVideoItem.fromJson(
    Map<String, dynamic> json, {
    String? fallbackBaseUrl,
  }) {
    final msgId = (json['msg_id'] is int)
        ? json['msg_id'] as int
        : int.tryParse((json['msg_id'] ?? '').toString());
    final hash = (json['hash'] ?? '').toString();
    final fileName = (json['file_name'] ?? 'video.mkv').toString();
    final rawStream = (json['stream_url'] ?? '').toString().trim();
    final resolvedStream = rawStream.isNotEmpty
        ? TelegramStreamService.normalizeDirectStreamUrl(rawStream)
        : (fallbackBaseUrl != null && msgId != null && hash.isNotEmpty
            ? '${TelegramStreamService.normalizeBaseUrl(fallbackBaseUrl)}/$msgId/${Uri.encodeComponent(fileName)}?hash=$hash'
            : '');

    final rawCode = (json['stream_code'] ?? '').toString().trim();
    final resolvedCode = rawCode.isNotEmpty
        ? rawCode.toUpperCase()
        : (msgId != null && hash.isNotEmpty
            ? 'MRDB-$msgId-${hash.toUpperCase()}'
            : '');

    final rawTmdb = json['tmdb_id'];
    final tmdbId = rawTmdb is int
        ? rawTmdb
        : int.tryParse((rawTmdb ?? '').toString());

    return TelegramVideoItem(
      msgId: msgId,
      hash: hash,
      streamCode: resolvedCode,
      title: (json['title'] ?? fileName).toString(),
      fileName: fileName,
      fileSize: (json['file_size'] is int)
          ? json['file_size'] as int
          : int.tryParse((json['file_size'] ?? '0').toString()) ?? 0,
      mimeType: (json['mime_type'] ?? 'video/x-matroska').toString(),
      tmdbId: tmdbId,
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()),
      streamUrl: resolvedStream,
      watchUrl: json['watch_url']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'msg_id': msgId,
        'hash': hash,
        'stream_code': streamCode,
        'title': title,
        'file_name': fileName,
        'file_size': fileSize,
        'mime_type': mimeType,
        'tmdb_id': tmdbId,
        'created_at': createdAt?.toIso8601String(),
        'stream_url': streamUrl,
        'watch_url': watchUrl,
      };
}

class TelegramVideosResult {
  final List<TelegramVideoItem> videos;
  final String baseUrl;
  final bool serverFeedSupported;
  final String? errorMessage;

  const TelegramVideosResult({
    required this.videos,
    required this.baseUrl,
    this.serverFeedSupported = true,
    this.errorMessage,
  });
}

class TelegramCodeLookupResult {
  final TelegramVideoItem? video;
  final String? errorMessage;

  const TelegramCodeLookupResult({this.video, this.errorMessage});
}

class TelegramStreamService {
  TelegramStreamService._();
  static final TelegramStreamService instance = TelegramStreamService._();

  static const String localTestBotUrl = 'http://127.0.0.1:8080';
  static const String _prefBaseUrlKey = 'telegram_stream_bot_url';
  static const String _prefSavedUrlsKey = 'telegram_saved_stream_items';

  static String normalizeBaseUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// Converts a bot `/watch/<id>/<name>?hash=...` HTML link into its direct
  /// HTTP Range stream URL `/<id>/<name>?hash=...` for native playback.
  static String normalizeDirectStreamUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return trimmed;
    final segments = List<String>.from(uri.pathSegments);
    if (segments.isNotEmpty && segments.first == 'watch') {
      segments.removeAt(0);
      return uri.replace(pathSegments: segments).toString();
    }
    return trimmed;
  }

  static bool isValidStreamUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return 'Unknown size';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var idx = 0;
    while (value >= 1024 && idx < units.length - 1) {
      value /= 1024;
      idx++;
    }
    final fixed = idx == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(value >= 100 ? 0 : 1);
    return '$fixed ${units[idx]}';
  }

  Future<String> resolveBaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final local = prefs.getString(_prefBaseUrlKey)?.trim() ?? '';
      if (local.isNotEmpty) return normalizeBaseUrl(local);
    } catch (_) {}

    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('keys')
          .get()
          .timeout(const Duration(seconds: 3));
      if (doc.exists) {
        final remote = doc.data()?['streamBotUrl']?.toString().trim() ?? '';
        if (remote.isNotEmpty) return normalizeBaseUrl(remote);
      }
    } catch (_) {}

    return AppConstants.defaultStreamBotUrl;
  }

  Future<void> saveCustomBaseUrl(String? rawUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = normalizeBaseUrl(rawUrl ?? '');
    if (normalized.isEmpty) {
      await prefs.remove(_prefBaseUrlKey);
    } else {
      await prefs.setString(_prefBaseUrlKey, normalized);
    }
  }

  Future<List<TelegramVideoItem>> getSavedManualVideos() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefSavedUrlsKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw) as List? ?? [];
      return decoded
          .whereType<Map>()
          .map((e) => TelegramVideoItem.fromJson(Map<String, dynamic>.from(e)))
          .where((v) => v.streamUrl.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveManualVideo(TelegramVideoItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getSavedManualVideos();
    final updated = [
      item,
      ...existing.where((v) => v.streamUrl != item.streamUrl),
    ].take(30).toList();
    await prefs.setString(
      _prefSavedUrlsKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeManualVideo(String streamUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getSavedManualVideos();
    final updated = existing.where((v) => v.streamUrl != streamUrl).toList();
    await prefs.setString(
      _prefSavedUrlsKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<String>> _candidateBaseUrls() async {
    final primary = await resolveBaseUrl();
    final urls = <String>[primary];
    if (primary != localTestBotUrl) {
      urls.add(localTestBotUrl);
    }
    return urls;
  }

  /// Resolves a unique Telegram bot Stream Code (`MRDB-...`) into a playable
  /// [TelegramVideoItem], automatically trying the local ADB test bot if the
  /// primary server does not support `/api/code/` yet.
  Future<TelegramCodeLookupResult> resolveStreamCode(String rawCode) async {
    final code = rawCode.trim();
    if (code.isEmpty) {
      return const TelegramCodeLookupResult(
        errorMessage: 'Enter a stream code from the bot',
      );
    }

    if (!await NetworkService.instance.hasInternet()) {
      // Still allow local 127.0.0.1:8080 over USB if offline
      return _lookupCodeAtBase(localTestBotUrl, code);
    }

    final candidates = await _candidateBaseUrls();
    TelegramCodeLookupResult? lastResult;
    for (final baseUrl in candidates) {
      final res = await _lookupCodeAtBase(baseUrl, code);
      if (res.video != null) return res;
      lastResult = res;
      // If code was explicitly not found (404) on a server that DOES support
      // /api/code/, still check local fallback in case user uploaded to test bot.
    }
    return lastResult ??
        const TelegramCodeLookupResult(
          errorMessage: 'Stream code not found. Check the code from the bot.',
        );
  }

  Future<TelegramCodeLookupResult> _lookupCodeAtBase(
    String baseUrl,
    String code,
  ) async {
    final uri = Uri.parse('$baseUrl/api/code/${Uri.encodeComponent(code)}');
    try {
      final res = await NetworkService.instance.client
          .get(uri)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic> &&
            decoded['ok'] == true &&
            decoded['video'] is Map) {
          final item = TelegramVideoItem.fromJson(
            Map<String, dynamic>.from(decoded['video'] as Map),
            fallbackBaseUrl: baseUrl,
          );
          if (item.streamUrl.isNotEmpty) {
            return TelegramCodeLookupResult(video: item);
          }
        }
      } else if (res.statusCode == 404) {
        return const TelegramCodeLookupResult(
          errorMessage: 'Stream code not found. Check the code from the bot.',
        );
      }
      return TelegramCodeLookupResult(
        errorMessage: 'Could not resolve code (HTTP ${res.statusCode})',
      );
    } catch (e) {
      if (e is FormatException) {
        return const TelegramCodeLookupResult(
          errorMessage: 'Server does not support stream codes yet.',
        );
      }
      final classified = await NetworkService.instance.classifyError(e);
      return TelegramCodeLookupResult(errorMessage: classified.message);
    }
  }

  Future<TelegramVideosResult> fetchBotVideos({
    String? query,
    int? tmdbId,
    int limit = 50,
  }) async {
    final candidates = await _candidateBaseUrls();
    final hasNet = await NetworkService.instance.hasInternet();
    final urlsToTry = hasNet ? candidates : [localTestBotUrl];

    TelegramVideosResult? lastResult;
    for (final baseUrl in urlsToTry) {
      final res = await _fetchBotVideosAtBase(
        baseUrl,
        query: query,
        tmdbId: tmdbId,
        limit: limit,
      );
      if (res.serverFeedSupported && res.errorMessage == null) {
        return res;
      }
      lastResult = res;
    }
    return lastResult ??
        TelegramVideosResult(
          videos: const [],
          baseUrl: candidates.first,
          errorMessage: 'Could not reach bot server',
        );
  }

  static String _normalizeMovieKey(TelegramVideoItem v) {
    final base = v.title.trim().isNotEmpty ? v.title : v.fileName;
    return base
        .toLowerCase()
        .replaceFirst(RegExp(r'\.(mkv|mp4|avi|mov|webm|m4v|ts|flv)$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Removes duplicate videos/movies (by stream code, URL, or normalized title),
  /// preserving the first (newest) entry.
  static List<TelegramVideoItem> dedupeVideos(List<TelegramVideoItem> items) {
    final seenCodes = <String>{};
    final seenUrls = <String>{};
    final seenTitles = <String>{};
    final unique = <TelegramVideoItem>[];
    for (final item in items) {
      final code = item.streamCode.trim().toUpperCase();
      final url = item.streamUrl.trim();
      final titleKey = _normalizeMovieKey(item);
      if (code.isNotEmpty && !seenCodes.add(code)) continue;
      if (url.isNotEmpty && !seenUrls.add(url)) continue;
      if (titleKey.isNotEmpty && !seenTitles.add(titleKey)) continue;
      unique.add(item);
    }
    return unique;
  }

  Future<TelegramVideosResult> _fetchBotVideosAtBase(
    String baseUrl, {
    String? query,
    int? tmdbId,
    int limit = 50,
  }) async {
    final queryParams = <String, String>{'limit': '$limit'};
    if (query != null && query.trim().isNotEmpty) {
      queryParams['q'] = query.trim();
    }
    if (tmdbId != null) {
      queryParams['tmdb_id'] = '$tmdbId';
    }
    final uri = Uri.parse('$baseUrl/api/videos').replace(
      queryParameters: queryParams,
    );

    try {
      final res = await NetworkService.instance.client
          .get(uri)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic> && decoded['videos'] is List) {
          final parsed = (decoded['videos'] as List)
              .whereType<Map>()
              .map(
                (e) => TelegramVideoItem.fromJson(
                  Map<String, dynamic>.from(e),
                  fallbackBaseUrl: baseUrl,
                ),
              )
              .where((v) => v.streamUrl.isNotEmpty)
              .toList();
          return TelegramVideosResult(
            videos: dedupeVideos(parsed),
            baseUrl: baseUrl,
            serverFeedSupported: true,
          );
        }
        return TelegramVideosResult(
          videos: const [],
          baseUrl: baseUrl,
          serverFeedSupported: false,
          errorMessage: 'Server at $baseUrl does not expose /api/videos yet.',
        );
      }

      return TelegramVideosResult(
        videos: const [],
        baseUrl: baseUrl,
        serverFeedSupported: res.statusCode != 404 && res.statusCode != 400,
        errorMessage: res.statusCode == 404 || res.statusCode == 400
            ? 'Server at $baseUrl needs the updated FileToLinkBot code deployed.'
            : 'Bot server error (HTTP ${res.statusCode})',
      );
    } catch (e) {
      if (e is FormatException) {
        return TelegramVideosResult(
          videos: const [],
          baseUrl: baseUrl,
          serverFeedSupported: false,
          errorMessage: 'Server at $baseUrl returned non-JSON response.',
        );
      }
      final classified = await NetworkService.instance.classifyError(e);
      return TelegramVideosResult(
        videos: const [],
        baseUrl: baseUrl,
        errorMessage: classified.message,
      );
    }
  }

  /// Searches TMDB movies DB so users can browse movies alongside bot files.
  Future<List<Map<String, dynamic>>> searchTmdbMovies(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final data = await NetworkService.instance.getTmdbJson(
        '/3/search/movie?api_key=${AppConstants.apiKey}&query=${Uri.encodeComponent(trimmed)}',
        timeout: const Duration(seconds: 8),
        maxAttempts: 2,
      );
      if (data is Map && data['results'] is List) {
        final seenIds = <dynamic>{};
        final unique = <Map<String, dynamic>>[];
        for (final raw in (data['results'] as List).whereType<Map>()) {
          final m = Map<String, dynamic>.from(raw);
          final id = m['id'];
          if (id != null && !seenIds.add(id)) continue;
          unique.add(m);
          if (unique.length >= 15) break;
        }
        return unique;
      }
    } catch (_) {}
    return const [];
  }
}
