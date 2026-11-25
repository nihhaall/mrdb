import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:path_provider/path_provider.dart';
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
  final String? thumbUrl;

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
    this.thumbUrl,
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

    final rawThumb = (json['thumb_url'] ?? '').toString().trim();
    String? resolvedThumb = rawThumb.isNotEmpty ? rawThumb : null;
    if (resolvedThumb == null && msgId != null) {
      if (fallbackBaseUrl != null && fallbackBaseUrl.trim().isNotEmpty) {
        resolvedThumb =
            '${TelegramStreamService.normalizeBaseUrl(fallbackBaseUrl)}/api/thumb/$msgId';
      } else if (resolvedStream.isNotEmpty) {
        try {
          final uri = Uri.parse(resolvedStream);
          resolvedThumb = '${uri.origin}/api/thumb/$msgId';
        } catch (_) {}
      }
    }

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
      thumbUrl: resolvedThumb,
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
        'thumb_url': thumbUrl,
      };
}

class TelegramVideosResult {
  final List<TelegramVideoItem> videos;
  final String baseUrl;
  final bool serverFeedSupported;
  final bool hasMore;
  final int rawCount;
  final String? errorMessage;

  const TelegramVideosResult({
    required this.videos,
    required this.baseUrl,
    this.serverFeedSupported = true,
    this.hasMore = false,
    this.rawCount = 0,
    this.errorMessage,
  });
}

class VideoWatchProgress {
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  const VideoWatchProgress({
    required this.positionMs,
    required this.durationMs,
    this.updatedAtMs = 0,
  });

  double get fraction => durationMs > 0
      ? (positionMs / durationMs).clamp(0.0, 1.0)
      : 0.0;

  bool get canResume =>
      positionMs >= 5000 &&
      (durationMs <= 0 || positionMs < durationMs - 10000);

  Map<String, dynamic> toJson() => {
    'position_ms': positionMs,
    'duration_ms': durationMs,
    'updated_at_ms': updatedAtMs,
  };

  factory VideoWatchProgress.fromJson(Map<String, dynamic> json) =>
      VideoWatchProgress(
        positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
      );
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
  static const String _prefWatchProgressKey = 'telegram_watch_progress_v1';

  static String progressKeyFor(TelegramVideoItem item) {
    final code = item.streamCode.trim().toUpperCase();
    if (code.isNotEmpty) return code;
    return item.streamUrl.trim();
  }

  Future<Map<String, VideoWatchProgress>> getAllWatchProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefWatchProgressKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final map = <String, VideoWatchProgress>{};
      for (final entry in decoded.entries) {
        if (entry.value is Map) {
          map[entry.key.toString()] = VideoWatchProgress.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveWatchProgress(
    String key,
    Duration position,
    Duration duration,
  ) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    final posMs = position.inMilliseconds;
    final durMs = duration.inMilliseconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await getAllWatchProgress();
      if (durMs > 0 && posMs >= durMs - 10000) {
        all.remove(trimmed);
      } else if (posMs >= 3000) {
        all[trimmed] = VideoWatchProgress(
          positionMs: posMs,
          durationMs: durMs,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      await prefs.setString(
        _prefWatchProgressKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {}
  }

  static const String _prefCapturedFramesKey =
      'telegram_stream_captured_frames';

  Future<String?> saveCapturedFrame(String key, Uint8List bytes) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty || bytes.isEmpty) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final framesDir = Directory('${dir.path}/stream_frames');
      if (!await framesDir.exists()) {
        await framesDir.create(recursive: true);
      }
      final safeKey = trimmed.hashCode.abs().toString();
      final file = File('${framesDir.path}/frame_$safeKey.jpg');
      await file.writeAsBytes(bytes, flush: true);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefCapturedFramesKey);
      final map = raw != null
          ? Map<String, String>.from(jsonDecode(raw) as Map)
          : <String, String>{};
      map[trimmed] = file.path;
      await prefs.setString(_prefCapturedFramesKey, jsonEncode(map));
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> getAllCapturedFrames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefCapturedFramesKey);
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw) as Map;
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final path = entry.value.toString();
        if (File(path).existsSync()) {
          result[entry.key.toString()] = path;
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<void> clearWatchProgress(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await getAllWatchProgress();
      all.remove(trimmed);
      await prefs.setString(
        _prefWatchProgressKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {}
  }

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
    int limit = 20,
    int offset = 0,
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
        offset: offset,
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
    int limit = 20,
    int offset = 0,
  }) async {
    final queryParams = <String, String>{
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
    };
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
          final rawCount = parsed.length;
          final hasMore =
              (decoded['has_more'] as bool?) ?? (rawCount >= limit);
          return TelegramVideosResult(
            videos: dedupeVideos(parsed),
            baseUrl: baseUrl,
            serverFeedSupported: true,
            hasMore: hasMore,
            rawCount: rawCount,
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

  Future<bool> deleteBotVideo(TelegramVideoItem item) async {
    final identifier = item.msgId != null
        ? '${item.msgId}'
        : item.streamCode.trim();
    if (identifier.isEmpty) return false;

    var deleted = false;
    final candidates = await _candidateBaseUrls();
    for (final baseUrl in candidates) {
      try {
        final uri = Uri.parse(
          '$baseUrl/api/videos/${Uri.encodeComponent(identifier)}',
        );
        final res = await NetworkService.instance.client
            .delete(uri)
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map && decoded['ok'] == true) {
            deleted = true;
            break;
          }
        }
      } catch (_) {}
    }

    await removeManualVideo(item.streamUrl);
    await clearWatchProgress(progressKeyFor(item));
    return deleted;
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

  static const String _ownerAdminKey = 'mrdb-owner-admin';

  Map<String, String> get _ownerHeaders => const {
    'X-Owner-Key': _ownerAdminKey,
    'Content-Type': 'application/json',
  };

  Future<BotAdminStats?> fetchBotAdminStats() async {
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final res = await NetworkService.instance.client
            .get(Uri.parse('$baseUrl/api/admin/stats'), headers: _ownerHeaders)
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['ok'] == true) {
            return BotAdminStats.fromJson(Map<String, dynamic>.from(data));
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<BotUsersResult> fetchBotUsers({
    String? query,
    int limit = 30,
    int offset = 0,
  }) async {
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final qp = <String, String>{
          'limit': '$limit',
          'offset': '$offset',
          if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        };
        final uri = Uri.parse('$baseUrl/api/admin/users').replace(queryParameters: qp);
        final res = await NetworkService.instance.client
            .get(uri, headers: _ownerHeaders)
            .timeout(const Duration(seconds: 7));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['ok'] == true) {
            final users = (data['users'] as List? ?? [])
                .whereType<Map>()
                .map((e) => BotUserItem.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            return BotUsersResult(
              users: users,
              totalUsers: (data['total_users'] as num?)?.toInt() ?? users.length,
              hasMore: data['has_more'] == true,
            );
          }
        }
      } catch (_) {}
    }
    return const BotUsersResult(
      users: [],
      totalUsers: 0,
      hasMore: false,
      errorMessage: 'Could not reach bot admin API.',
    );
  }

  Future<bool> setBotUserBanned(int userId, {required bool ban}) async {
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final uri = Uri.parse('$baseUrl/api/admin/users/$userId/ban');
        final res = ban
            ? await NetworkService.instance.client
                .post(uri, headers: _ownerHeaders)
                .timeout(const Duration(seconds: 6))
            : await NetworkService.instance.client
                .delete(uri, headers: _ownerHeaders)
                .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['ok'] == true) return true;
        }
      } catch (_) {}
    }
    return false;
  }

  Future<BotBroadcastResult> sendBotBroadcast(String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return const BotBroadcastResult(ok: false, error: 'Message cannot be empty');
    }
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final res = await NetworkService.instance.client
            .post(
              Uri.parse('$baseUrl/api/admin/broadcast'),
              headers: _ownerHeaders,
              body: jsonEncode({'message': trimmed}),
            )
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['ok'] == true) {
            return BotBroadcastResult(
              ok: true,
              total: (data['total'] as num?)?.toInt() ?? 0,
              sent: (data['sent'] as num?)?.toInt() ?? 0,
              failed: (data['failed'] as num?)?.toInt() ?? 0,
              done: data['done'] ?? true,
              jobId: data['job_id']?.toString(),
              baseUrl: baseUrl,
            );
          }
        }
      } catch (_) {}
    }
    return const BotBroadcastResult(ok: false, error: 'Broadcast request failed');
  }

  Future<BotBroadcastResult?> fetchBroadcastStatus(
    String baseUrl,
    String jobId,
  ) async {
    try {
      final res = await NetworkService.instance.client
          .get(
            Uri.parse('$baseUrl/api/admin/broadcast/${Uri.encodeComponent(jobId)}'),
            headers: _ownerHeaders,
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['ok'] == true) {
          return BotBroadcastResult(
            ok: true,
            total: (data['total'] as num?)?.toInt() ?? 0,
            sent: (data['sent'] as num?)?.toInt() ?? 0,
            failed: (data['failed'] as num?)?.toInt() ?? 0,
            done: data['done'] == true,
            jobId: jobId,
            baseUrl: baseUrl,
          );
        }
      }
    } catch (_) {}
    return null;
  }
}

class BotAdminStats {
  final int totalUsers;
  final int bannedUsers;
  final int totalVideos;
  final String uptime;
  final String telegramBot;
  final int connectedBots;
  final Map<String, int> loads;

  const BotAdminStats({
    required this.totalUsers,
    required this.bannedUsers,
    required this.totalVideos,
    required this.uptime,
    required this.telegramBot,
    required this.connectedBots,
    this.loads = const {},
  });

  factory BotAdminStats.fromJson(Map<String, dynamic> json) {
    final rawLoads = json['loads'];
    final parsedLoads = <String, int>{};
    if (rawLoads is Map) {
      for (final e in rawLoads.entries) {
        parsedLoads[e.key.toString()] = (e.value as num?)?.toInt() ?? 0;
      }
    }
    return BotAdminStats(
      totalUsers: (json['total_users'] as num?)?.toInt() ?? 0,
      bannedUsers: (json['banned_users'] as num?)?.toInt() ?? 0,
      totalVideos: (json['total_videos'] as num?)?.toInt() ?? 0,
      uptime: (json['uptime'] ?? '-').toString(),
      telegramBot: (json['telegram_bot'] ?? '').toString(),
      connectedBots: (json['connected_bots'] as num?)?.toInt() ?? 0,
      loads: parsedLoads,
    );
  }
}

class BotUserItem {
  final int id;
  final String name;
  final String username;
  final String joinDate;
  final bool isBanned;

  const BotUserItem({
    required this.id,
    this.name = '',
    this.username = '',
    required this.joinDate,
    required this.isBanned,
  });

  BotUserItem copyWith({bool? isBanned}) => BotUserItem(
    id: id,
    name: name,
    username: username,
    joinDate: joinDate,
    isBanned: isBanned ?? this.isBanned,
  );

  factory BotUserItem.fromJson(Map<String, dynamic> json) => BotUserItem(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: (json['name'] ?? '').toString(),
    username: (json['username'] ?? '').toString(),
    joinDate: (json['join_date'] ?? '').toString(),
    isBanned: json['is_banned'] == true,
  );
}

class BotUsersResult {
  final List<BotUserItem> users;
  final int totalUsers;
  final bool hasMore;
  final String? errorMessage;

  const BotUsersResult({
    required this.users,
    required this.totalUsers,
    required this.hasMore,
    this.errorMessage,
  });
}

class BotBroadcastResult {
  final bool ok;
  final int total;
  final int sent;
  final int failed;
  final bool done;
  final String? jobId;
  final String? baseUrl;
  final String? error;

  const BotBroadcastResult({
    required this.ok,
    this.total = 0,
    this.sent = 0,
    this.failed = 0,
    this.done = true,
    this.jobId,
    this.baseUrl,
    this.error,
  });
}
