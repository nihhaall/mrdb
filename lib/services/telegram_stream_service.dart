import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VideoAudioTrackInfo {
  final int index;
  final int streamIndex;
  final String language;
  final String codec;
  final String channels;
  final String title;
  final bool isDefault;

  const VideoAudioTrackInfo({
    required this.index,
    this.streamIndex = 0,
    this.language = 'und',
    this.codec = '',
    this.channels = '',
    this.title = '',
    this.isDefault = false,
  });

  String get displayLabel {
    final parts = <String>[];
    if (title.trim().isNotEmpty) {
      parts.add(title.trim());
    }
    final lang = language.trim();
    if (lang.isNotEmpty && lang.toLowerCase() != 'und') {
      final upper = lang.toUpperCase();
      if (!parts.any((p) => p.toUpperCase().contains(upper))) {
        parts.add(upper);
      }
    }
    if (codec.trim().isNotEmpty) {
      parts.add(codec.trim().toUpperCase());
    }
    if (channels.trim().isNotEmpty) {
      parts.add(channels.trim());
    }
    if (parts.isEmpty) return 'Audio Track ${index + 1}';
    return parts.join(' • ');
  }

  VideoAudioTrackInfo copyWith({
    String? title,
    String? language,
    bool? isDefault,
  }) =>
      VideoAudioTrackInfo(
        index: index,
        streamIndex: streamIndex,
        language: language ?? this.language,
        codec: codec,
        channels: channels,
        title: title ?? this.title,
        isDefault: isDefault ?? this.isDefault,
      );

  factory VideoAudioTrackInfo.fromJson(Map<String, dynamic> json) =>
      VideoAudioTrackInfo(
        index: (json['index'] as num?)?.toInt() ?? 0,
        streamIndex: (json['stream_index'] as num?)?.toInt() ?? 0,
        language: (json['language'] ?? 'und').toString(),
        codec: (json['codec'] ?? '').toString(),
        channels: (json['channels'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        isDefault: json['is_default'] == true,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'stream_index': streamIndex,
        'language': language,
        'codec': codec,
        'channels': channels,
        'title': title,
        'is_default': isDefault,
      };
}

class VideoTracksInspectResult {
  final bool ok;
  final List<VideoAudioTrackInfo> tracks;
  final List<int> disabledAudioIndices;
  final String? errorMessage;

  const VideoTracksInspectResult({
    this.ok = false,
    this.tracks = const [],
    this.disabledAudioIndices = const [],
    this.errorMessage,
  });
}

class TelegramVideoItem {
  final int? msgId;
  final String hash;
  final String streamCode;
  final String title;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final int? tmdbId;
  final String? tmdbTitle;
  final String? tmdbPoster;
  final String? tmdbYear;
  final int? year;
  final String? quality;
  final String? language;
  final String? overview;
  final bool metadataEdited;
  final bool hiddenForUsers;
  final List<int> disabledAudioIndices;
  final List<VideoAudioTrackInfo> audioTracks;
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
    this.tmdbTitle,
    this.tmdbPoster,
    this.tmdbYear,
    this.year,
    this.quality,
    this.language,
    this.overview,
    this.metadataEdited = false,
    this.hiddenForUsers = false,
    this.disabledAudioIndices = const [],
    this.audioTracks = const [],
    this.createdAt,
    required this.streamUrl,
    this.watchUrl,
    this.thumbUrl,
  });

  bool get isMkv =>
      fileName.toLowerCase().endsWith('.mkv') ||
      mimeType.toLowerCase().contains('matroska');

  String get formatBadge {
    final q = quality?.trim() ?? '';
    if (q.isNotEmpty) return q.toUpperCase();
    final lower = fileName.toLowerCase();
    for (final ext in const ['.mkv', '.mp4', '.webm', '.mov', '.avi', '.m4v']) {
      if (lower.endsWith(ext)) return ext.substring(1).toUpperCase();
    }
    if (mimeType.toLowerCase().contains('matroska')) return 'MKV';
    if (mimeType.toLowerCase().contains('mp4')) return 'MP4';
    return 'VIDEO';
  }

  TelegramVideoItem copyWith({
    String? title,
    int? year,
    bool clearYear = false,
    String? quality,
    String? language,
    String? overview,
    int? tmdbId,
    bool clearTmdb = false,
    String? tmdbTitle,
    String? tmdbPoster,
    String? tmdbYear,
    bool? metadataEdited,
    bool? hiddenForUsers,
    List<int>? disabledAudioIndices,
    List<VideoAudioTrackInfo>? audioTracks,
  }) {
    return TelegramVideoItem(
      msgId: msgId,
      hash: hash,
      streamCode: streamCode,
      title: title ?? this.title,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      tmdbId: clearTmdb ? null : (tmdbId ?? this.tmdbId),
      tmdbTitle: clearTmdb ? null : (tmdbTitle ?? this.tmdbTitle),
      tmdbPoster: clearTmdb ? null : (tmdbPoster ?? this.tmdbPoster),
      tmdbYear: clearTmdb ? null : (tmdbYear ?? this.tmdbYear),
      year: clearYear ? null : (year ?? this.year),
      quality: quality ?? this.quality,
      language: language ?? this.language,
      overview: overview ?? this.overview,
      metadataEdited: metadataEdited ?? this.metadataEdited,
      hiddenForUsers: hiddenForUsers ?? this.hiddenForUsers,
      disabledAudioIndices: disabledAudioIndices ?? this.disabledAudioIndices,
      audioTracks: audioTracks ?? this.audioTracks,
      createdAt: createdAt,
      streamUrl: streamUrl,
      watchUrl: watchUrl,
      thumbUrl: thumbUrl,
    );
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

    final rawYear = json['year'];
    final year = rawYear is int
        ? rawYear
        : int.tryParse((rawYear ?? '').toString());

    String? cleanOptStr(dynamic v) {
      final s = v?.toString().trim() ?? '';
      return s.isEmpty || s == 'null' ? null : s;
    }

    final disabledRaw = json['disabled_audio_indices'];
    final disabledAudio = <int>[];
    if (disabledRaw is List) {
      for (final x in disabledRaw) {
        final parsed = x is int ? x : int.tryParse(x.toString());
        if (parsed != null && parsed >= 0) disabledAudio.add(parsed);
      }
    }

    final tracksRaw = json['audio_tracks'];
    final parsedTracks = <VideoAudioTrackInfo>[];
    if (tracksRaw is List) {
      for (final t in tracksRaw.whereType<Map>()) {
        parsedTracks.add(
          VideoAudioTrackInfo.fromJson(Map<String, dynamic>.from(t)),
        );
      }
    }

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

    final metadataEdited = json['metadata_edited'] == true;
    final rawTitle = (json['title'] ?? '').toString().trim();

    return TelegramVideoItem(
      msgId: msgId,
      hash: hash,
      streamCode: resolvedCode,
      title: metadataEdited && rawTitle.isNotEmpty ? rawTitle : fileName,
      fileName: fileName,
      fileSize: (json['file_size'] is int)
          ? json['file_size'] as int
          : int.tryParse((json['file_size'] ?? '0').toString()) ?? 0,
      mimeType: (json['mime_type'] ?? 'video/x-matroska').toString(),
      tmdbId: tmdbId,
      tmdbTitle: cleanOptStr(json['tmdb_title']),
      tmdbPoster: cleanOptStr(json['tmdb_poster']),
      tmdbYear: cleanOptStr(json['tmdb_year']),
      year: year,
      quality: cleanOptStr(json['quality']),
      language: cleanOptStr(json['language']),
      overview: cleanOptStr(json['overview']),
      metadataEdited: metadataEdited,
      hiddenForUsers: json['hidden_for_users'] == true,
      disabledAudioIndices: disabledAudio,
      audioTracks: parsedTracks,
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
        'tmdb_title': tmdbTitle,
        'tmdb_poster': tmdbPoster,
        'tmdb_year': tmdbYear,
        'year': year,
        'quality': quality,
        'language': language,
        'overview': overview,
        'metadata_edited': metadataEdited,
        'hidden_for_users': hiddenForUsers,
        'disabled_audio_indices': disabledAudioIndices,
        'audio_tracks': audioTracks.map((t) => t.toJson()).toList(),
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
  final int? totalCount;
  final String? errorMessage;

  const TelegramVideosResult({
    required this.videos,
    required this.baseUrl,
    this.serverFeedSupported = true,
    this.hasMore = false,
    this.rawCount = 0,
    this.totalCount,
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
      'telegram_stream_captured_frames_10m';
  static const String _prefLastFramesKey =
      'telegram_stream_last_frames_v1';

  Future<String?> saveCapturedFrame(String key, Uint8List bytes) =>
      _saveFrameEntry(
        key: key,
        bytes: bytes,
        prefKey: _prefCapturedFramesKey,
        filePrefix: 'frame',
        versioned: false,
      );

  /// Saves the latest frame from the position where the user paused or exited,
  /// using a fresh filename so Flutter renders the updated frame immediately.
  Future<String?> saveLastFrame(String key, Uint8List bytes) =>
      _saveFrameEntry(
        key: key,
        bytes: bytes,
        prefKey: _prefLastFramesKey,
        filePrefix: 'last_frame',
        versioned: true,
      );

  Future<String?> _saveFrameEntry({
    required String key,
    required Uint8List bytes,
    required String prefKey,
    required String filePrefix,
    required bool versioned,
  }) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty || bytes.isEmpty) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final framesDir = Directory('${dir.path}/stream_frames');
      if (!await framesDir.exists()) {
        await framesDir.create(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
      final map = raw != null
          ? Map<String, String>.from(jsonDecode(raw) as Map)
          : <String, String>{};
      final previousPath = map[trimmed];

      final safeKey = trimmed.hashCode.abs().toString();
      final suffix =
          versioned ? '_${DateTime.now().millisecondsSinceEpoch}' : '';
      final file = File('${framesDir.path}/${filePrefix}_$safeKey$suffix.jpg');
      await file.writeAsBytes(bytes, flush: true);

      if (previousPath != null &&
          previousPath != file.path &&
          File(previousPath).existsSync()) {
        try {
          await File(previousPath).delete();
        } catch (_) {}
      }

      map[trimmed] = file.path;
      await prefs.setString(prefKey, jsonEncode(map));
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> getAllCapturedFrames() =>
      _getFramesFromPref(_prefCapturedFramesKey);

  Future<Map<String, String>> getAllLastFrames() =>
      _getFramesFromPref(_prefLastFramesKey);

  Future<Map<String, String>> _getFramesFromPref(String prefKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
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

  Future<void> clearLastFrame(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefLastFramesKey);
      if (raw == null || raw.isEmpty) return;
      final map = Map<String, String>.from(jsonDecode(raw) as Map);
      final existing = map.remove(trimmed);
      await prefs.setString(_prefLastFramesKey, jsonEncode(map));
      if (existing != null && File(existing).existsSync()) {
        try {
          await File(existing).delete();
        } catch (_) {}
      }
    } catch (_) {}
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
      await clearLastFrame(trimmed);
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
    final urls = <String>[
      if (kDebugMode && primary != localTestBotUrl) localTestBotUrl,
      primary,
      if (!kDebugMode && primary != localTestBotUrl) localTestBotUrl,
    ];
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
    bool includeHidden = false,
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
        includeHidden: includeHidden,
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

  static String _normalizeNameKey(String raw) {
    return raw
        .toLowerCase()
        .replaceFirst(RegExp(r'\.(mkv|mp4|avi|mov|webm|m4v|ts|flv)$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Removes duplicate videos/movies (by msgId, stream code, URL, file name, or title),
  /// preferring owner-edited entries over unedited pre-edit duplicates.
  static List<TelegramVideoItem> dedupeVideos(List<TelegramVideoItem> items) {
    final prioritized = <TelegramVideoItem>[
      ...items.where((v) => v.metadataEdited),
      ...items.where((v) => !v.metadataEdited),
    ];
    final seenMsgIds = <int>{};
    final seenCodes = <String>{};
    final seenUrls = <String>{};
    final seenFileNames = <String>{};
    final seenTitles = <String>{};
    final unique = <TelegramVideoItem>[];
    for (final item in prioritized) {
      final code = item.streamCode.trim().toUpperCase();
      final url = item.streamUrl.trim();
      final fileKey = _normalizeNameKey(item.fileName);
      final titleKey = _normalizeNameKey(
        item.title.trim().isNotEmpty ? item.title : item.fileName,
      );
      if (item.msgId != null && !seenMsgIds.add(item.msgId!)) continue;
      if (code.isNotEmpty && !seenCodes.add(code)) continue;
      if (url.isNotEmpty && !seenUrls.add(url)) continue;
      if (fileKey.isNotEmpty && !seenFileNames.add(fileKey)) continue;
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
    bool includeHidden = false,
  }) async {
    final queryParams = <String, String>{
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
      if (includeHidden) 'include_hidden': '1',
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
          .get(uri, headers: includeHidden ? _ownerHeaders : null)
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
          final totalCount = (decoded['total'] as num?)?.toInt();
          return TelegramVideosResult(
            videos: dedupeVideos(parsed),
            baseUrl: baseUrl,
            serverFeedSupported: true,
            hasMore: hasMore,
            rawCount: rawCount,
            totalCount: totalCount,
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

  static final RegExp _emojiAndSymbolsRegex = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2300}-\u{23FF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]',
    unicode: true,
  );

  /// Derives a clean search query / display name from a release filename or title,
  /// stripping emojis, Telegram @mentions/links, file extensions, and rip tags.
  static String cleanSearchTitle(String raw) {
    return raw
        .replaceAll(RegExp(r'(?:https?://|t\.me/)\S+', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'@[A-Za-z0-9_.]+'), ' ')
        .replaceAll(_emojiAndSymbolsRegex, ' ')
        .replaceAll(
          RegExp(r'(?:\.(?:mkv|mp4|avi|mov|webm|m4v|ts|flv))+$', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(
          RegExp(
            r'\b(2160p|4k|1080p|720p|480p|360p|hdrip|remastered|web[-\s]?dl|webrip|bluray|brrip|x264|x265|hevc|h\.?264|h\.?265|10bit|aac|eac3|ac3|ddp?5\s?1|esub|sub|multi|dual)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\[\(]\s*[\]\)]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s\-|:_/\[\]]+|[\s\-|:_/\[\]]+$'), '')
        .trim();
  }

  static final Map<String, String> _languageTokenMap = {
    'mal': 'Malayalam',
    'ml': 'Malayalam',
    'malayalam': 'Malayalam',
    'tam': 'Tamil',
    'ta': 'Tamil',
    'tamil': 'Tamil',
    'hin': 'Hindi',
    'hi': 'Hindi',
    'hindi': 'Hindi',
    'tel': 'Telugu',
    'te': 'Telugu',
    'telugu': 'Telugu',
    'kan': 'Kannada',
    'kn': 'Kannada',
    'kannada': 'Kannada',
    'eng': 'English',
    'en': 'English',
    'english': 'English',
    'kor': 'Korean',
    'ko': 'Korean',
    'korean': 'Korean',
    'jap': 'Japanese',
    'jpn': 'Japanese',
    'ja': 'Japanese',
    'japanese': 'Japanese',
    'spa': 'Spanish',
    'es': 'Spanish',
    'spanish': 'Spanish',
    'fre': 'French',
    'fra': 'French',
    'fr': 'French',
    'french': 'French',
    'ger': 'German',
    'deu': 'German',
    'de': 'German',
    'german': 'German',
    'ita': 'Italian',
    'it': 'Italian',
    'italian': 'Italian',
    'zh': 'Chinese',
    'chi': 'Chinese',
    'chinese': 'Chinese',
    'ar': 'Arabic',
    'ara': 'Arabic',
    'arabic': 'Arabic',
    'ru': 'Russian',
    'rus': 'Russian',
    'russian': 'Russian',
    'mr': 'Marathi',
    'mar': 'Marathi',
    'marathi': 'Marathi',
    'bn': 'Bengali',
    'ben': 'Bengali',
    'bengali': 'Bengali',
    'pa': 'Punjabi',
    'pun': 'Punjabi',
    'punjabi': 'Punjabi',
    'gu': 'Gujarati',
    'guj': 'Gujarati',
    'gujarati': 'Gujarati',
  };

  /// Maps ISO-639-1/2 or language names (e.g. `kn`, `ml`, `ta`) to display name.
  static String? mapLanguageCode(String? code) {
    final clean = (code ?? '').trim().toLowerCase();
    if (clean.isEmpty || clean == 'und' || clean == 'null') return null;
    return _languageTokenMap[clean];
  }

  static const String _geminiApiKeyPref = 'mrdb_gemini_api_key';
  static const String _aiPromptPresetPref = 'mrdb_ai_prompt_preset';

  static const String defaultAiPromptPreset =
      'Correct the movie or series file name into a standard format: '
      'MovieName (Year) Language Quality, like "OM (2026) Tamil" or "OM (2026) Tamil 1080p". '
      'For series, include Season and Episode like "Breaking Bad S02E05 (2009) English 1080p".';

  /// Returns the owner-configured Google Gemini API key, if any.
  Future<String?> getGeminiApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_geminiApiKeyPref)?.trim();
    return (key != null && key.isNotEmpty) ? key : null;
  }

  /// Saves or clears the owner's Google Gemini API key.
  Future<void> setGeminiApiKey(String? key) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = key?.trim() ?? '';
    if (trimmed.isEmpty) {
      await prefs.remove(_geminiApiKeyPref);
    } else {
      await prefs.setString(_geminiApiKeyPref, trimmed);
    }
  }

  /// Returns the owner's AI prompt preset, falling back to [defaultAiPromptPreset].
  Future<String> getAiPromptPreset() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_aiPromptPresetPref)?.trim();
    return (saved != null && saved.isNotEmpty) ? saved : defaultAiPromptPreset;
  }

  /// Saves or resets the owner's AI prompt preset.
  Future<void> setAiPromptPreset(String? preset) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = preset?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == defaultAiPromptPreset) {
      await prefs.remove(_aiPromptPresetPref);
    } else {
      await prefs.setString(_aiPromptPresetPref, trimmed);
    }
  }

  /// Formats a clean display name using the standard format:
  /// `MovieName (Year) Language Quality` (with `SxxExx` for series).
  static String buildStandardFileName({
    required String baseTitle,
    int? year,
    String? language,
    String? quality,
    int? season,
    int? episode,
  }) {
    final parts = <String>[baseTitle.trim()];
    final seriesTag = formatSeriesTag(season, episode);
    if (seriesTag.isNotEmpty && !baseTitle.toUpperCase().contains(seriesTag)) {
      parts.add(seriesTag);
    }
    if (year != null) {
      parts.add('($year)');
    }
    final cleanLang = language?.trim() ?? '';
    if (cleanLang.isNotEmpty) {
      parts.add(cleanLang);
    }
    final cleanQual = quality?.trim() ?? '';
    if (cleanQual.isNotEmpty) {
      parts.add(cleanQual);
    }
    return parts.where((p) => p.isNotEmpty).join(' ');
  }

  /// Formats season/episode numbers into a standard tag like `S02E05` or `S02`.
  static String formatSeriesTag(int? season, int? episode) {
    if (season != null && episode != null) {
      return 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    }
    if (season != null) {
      return 'S${season.toString().padLeft(2, '0')}';
    }
    if (episode != null) {
      return 'E${episode.toString().padLeft(2, '0')}';
    }
    return '';
  }

  /// Analyzes a raw release filename locally (unlimited & offline) to extract
  /// clean movie/series title, season/episode, release year, quality, and languages.
  static SmartFileNameSuggestion analyzeFileNameLocally(
    String rawFileName, {
    String? existingTitle,
  }) {
    final primary = (existingTitle != null && existingTitle.trim().isNotEmpty)
        ? '${existingTitle.trim()} $rawFileName'
        : rawFileName;

    // 0. Series detection (S01E02, S1 E2, Season 1 Episode 2, S01)
    int? season;
    int? episode;
    final seMatch = RegExp(
      r'\bS(\d{1,2})\s*[-._ ]?\s*E(\d{1,3})\b',
      caseSensitive: false,
    ).firstMatch(primary) ??
        RegExp(
          r'\bSeason\s*(\d{1,2})\s*(?:Episode|Ep\.?)\s*(\d{1,3})\b',
          caseSensitive: false,
        ).firstMatch(primary);
    if (seMatch != null) {
      season = int.tryParse(seMatch.group(1)!);
      episode = int.tryParse(seMatch.group(2)!);
    } else {
      final sOnly = RegExp(
        r'\b(?:S(\d{1,2})|Season\s*(\d{1,2}))\b',
        caseSensitive: false,
      ).firstMatch(primary);
      if (sOnly != null) {
        season = int.tryParse(sOnly.group(1) ?? sOnly.group(2) ?? '');
      }
    }
    final isSeries = season != null || episode != null;

    // 1. Quality (prefer explicit resolution over HDRip)
    String? quality;
    final resMatch = RegExp(
      r'\b(2160p|4K|1080p|720p|480p|360p)\b',
      caseSensitive: false,
    ).firstMatch(primary);
    if (resMatch != null) {
      final rawQ = resMatch.group(1)!.toLowerCase();
      quality = (rawQ == '2160p' || rawQ == '4k') ? '4K' : rawQ;
    } else if (RegExp(r'\bHDRip\b', caseSensitive: false).hasMatch(primary)) {
      quality = 'HDRip';
    }

    // 2. Year
    int? year;
    final yMatch = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(rawFileName) ??
        RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(primary);
    if (yMatch != null) {
      year = int.tryParse(yMatch.group(1)!);
    }

    // 3. Languages
    final langs = <String>[];
    final seenLang = <String>{};
    for (final m in RegExp(r'\b[A-Za-z]{3,10}\b').allMatches(primary)) {
      final mapped = _languageTokenMap[m.group(0)!.toLowerCase()];
      if (mapped != null && seenLang.add(mapped)) {
        langs.add(mapped);
      }
    }

    // 4. Clean display & search title
    final baseForTitle = (existingTitle != null &&
            existingTitle.trim().isNotEmpty &&
            existingTitle.trim() != rawFileName.trim())
        ? existingTitle.trim()
        : rawFileName;

    var stripped = baseForTitle
        .replaceAll(RegExp(r'^\[[^\]]{1,12}\]\s*'), '')
        .replaceAll(RegExp(r'\[[^\]]*(?:hin|mal|tam|tel|kan|eng|ddp|aac|hevc)[^\]]*\]', caseSensitive: false), ' ');
    stripped = cleanSearchTitle(stripped);
    final langWordsPattern = _languageTokenMap.keys
        .where((k) => k.length >= 3)
        .map(RegExp.escape)
        .join('|');
    stripped = stripped
        .replaceAll(
          RegExp(
            '\\b($langWordsPattern)\\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:S\d{1,2}\s*[-._ ]?\s*E\d{1,3}|Season\s*\d{1,2}(?:\s*(?:Episode|Ep\.?)\s*\d{1,3})?|S\d{1,2})\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\(\[]\s*(19\d{2}|20\d{2})?\s*[\)\]]'), ' ')
        .replaceAll(RegExp(r'[,+&•]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s\-|:_/\[\](),+&•]+|[\s\-|:_/\[\](),+&•]+$'), '')
        .trim();

    final searchQuery = stripped
        .replaceAll(RegExp(r'\b(19\d{2}|20\d{2})\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s\-|:_/\[\](),+&•]+|[\s\-|:_/\[\](),+&•]+$'), '')
        .trim();

    final baseTitle = searchQuery.isNotEmpty
        ? searchQuery
        : (stripped.isNotEmpty ? stripped : cleanSearchTitle(rawFileName));
    final seriesTag = formatSeriesTag(season, episode);
    final displayTitle = (seriesTag.isNotEmpty && baseTitle.isNotEmpty)
        ? '$baseTitle $seriesTag'
        : baseTitle;

    return SmartFileNameSuggestion(
      title: displayTitle,
      searchQuery: searchQuery.isNotEmpty ? searchQuery : cleanSearchTitle(rawFileName),
      year: year,
      quality: quality,
      language: langs.isNotEmpty ? langs.join(', ') : null,
      matchedTmdb: false,
      usedAi: false,
      isSeries: isSeries,
      season: season,
      episode: episode,
      aiProvider: 'Local',
    );
  }

  /// Parses an AI JSON response into a [SmartFileNameSuggestion], stripping
  /// optional markdown code fences or surrounding prose.
  static SmartFileNameSuggestion? parseAiSuggestionJson(
    String rawContent, {
    required String rawFileName,
    String aiProvider = 'Pollinations AI',
  }) {
    final start = rawContent.indexOf('{');
    final end = rawContent.lastIndexOf('}');
    if (start == -1 || end <= start) return null;
    try {
      final decoded = jsonDecode(rawContent.substring(start, end + 1));
      if (decoded is! Map<String, dynamic>) return null;
      var baseTitle = (decoded['title'] ?? '').toString().trim();
      if (baseTitle.isEmpty) return null;

      int? parseOptInt(dynamic v, {int min = 0, int max = 9999}) {
        if (v is int && v >= min && v <= max) return v;
        if (v != null) {
          final p = int.tryParse(v.toString().trim());
          if (p != null && p >= min && p <= max) return p;
        }
        return null;
      }

      final year = parseOptInt(decoded['year'], min: 1900, max: 2100);
      final season = parseOptInt(decoded['season'], min: 1, max: 99);
      final episode = parseOptInt(decoded['episode'], min: 1, max: 999);
      final mediaType = (decoded['media_type'] ?? '').toString().toLowerCase().trim();
      final isSeries = mediaType == 'tv' ||
          mediaType == 'series' ||
          season != null ||
          episode != null;

      // Strip any trailing SxxExx from searchQuery so TMDB TV search matches cleanly.
      final cleanedShowTitle = baseTitle
          .replaceAll(
            RegExp(r'\s*\bS\d{1,2}\s*E\d{1,3}\b\s*$', caseSensitive: false),
            '',
          )
          .trim();
      if (cleanedShowTitle.isNotEmpty) {
        baseTitle = cleanedShowTitle;
      }

      String? quality;
      final rawQuality = (decoded['quality'] ?? '').toString().trim();
      if (rawQuality.isNotEmpty && rawQuality.toLowerCase() != 'null') {
        quality = rawQuality.toLowerCase() == '2160p' ? '4K' : rawQuality;
      }

      String? readLangField(dynamic val) {
        if (val is List) {
          final joined = val
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty && e.toLowerCase() != 'null')
              .join(', ');
          return joined.isNotEmpty ? joined : null;
        }
        if (val != null) {
          final s = val.toString().trim();
          if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
        }
        return null;
      }

      final language =
          readLangField(decoded['filename_languages']) ??
          readLangField(decoded['language']) ??
          readLangField(decoded['original_language']);

      final formattedName = (decoded['formatted_name'] ?? '').toString().trim();
      final displayTitle = formattedName.isNotEmpty
          ? formattedName
          : buildStandardFileName(
              baseTitle: baseTitle,
              year: year,
              language: language,
              quality: quality,
              season: season,
              episode: episode,
            );
      final searchQuery = cleanSearchTitle(baseTitle);

      return SmartFileNameSuggestion(
        title: displayTitle,
        searchQuery: searchQuery.isNotEmpty ? searchQuery : baseTitle,
        year: year,
        quality: quality,
        language: language,
        matchedTmdb: false,
        usedAi: true,
        isSeries: isSeries,
        season: season,
        episode: episode,
        aiProvider: aiProvider,
      );
    } catch (_) {
      return null;
    }
  }

  static String _buildAiSystemPrompt(String promptPreset) =>
      'You clean messy Telegram movie or TV series release filenames into proper metadata. '
      'Follow this formatting instruction from the user for formatted_name: $promptPreset '
      'If it is a TV series/episode (e.g. S01E02, Season 2 Episode 5), set media_type to "tv" and extract integer season and episode. '
      'Otherwise set media_type to "movie" and season/episode to null. '
      'Respond ONLY with a single valid JSON object containing keys: '
      'title (string: clean movie or series name ONLY, without season/episode, channel handles, URLs, codecs, file sizes, languages, or year), '
      'formatted_name (string: full corrected file name following the user formatting instruction), '
      'media_type ("movie" or "tv"), '
      'season (integer or null), '
      'episode (integer or null), '
      'year (integer or null), '
      'quality (string like "4K", "1080p", "720p", "480p", "HDRip", or null), '
      'language (string like "Malayalam" or "Tamil, Hindi" if in filename, or null), '
      'original_language (string: the exact primary original language of this movie/series from your movie knowledge, e.g. "Kannada", "Malayalam", "Tamil", "Hindi", "English").';

  Future<SmartFileNameSuggestion?> _analyzeWithGemini(
    String apiKey,
    String trimmedRaw,
    String trimmedExisting,
    String promptPreset,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=${Uri.encodeQueryComponent(apiKey)}',
      );
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 22));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': _buildAiSystemPrompt(promptPreset)},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {
                  'text':
                      'Raw filename: $trimmedRaw\nExisting title in editor: $trimmedExisting',
                },
              ],
            },
          ],
          'generationConfig': {
            'temperature': 0.1,
            'responseMimeType': 'application/json',
          },
        }),
      );
      final res = await req.close().timeout(const Duration(seconds: 22));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final rawText = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 22));
      final body = jsonDecode(rawText);
      if (body is! Map<String, dynamic>) return null;
      final candidates = body['candidates'];
      if (candidates is! List || candidates.isEmpty) return null;
      final first = candidates.first;
      if (first is! Map) return null;
      final content = first['content'];
      if (content is! Map) return null;
      final parts = content['parts'];
      if (parts is! List || parts.isEmpty) return null;
      final text = (parts.first is Map ? parts.first['text'] : '').toString();
      return parseAiSuggestionJson(
        text,
        rawFileName: trimmedRaw,
        aiProvider: 'Gemini',
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Uses Google Gemini (when an API key is saved by the owner) or the free,
  /// zero-key Pollinations OpenAI-compatible API to analyze the raw Telegram
  /// filename together with the existing editor title.
  Future<SmartFileNameSuggestion?> analyzeFileNameWithAi(
    String rawFileName, {
    String? existingTitle,
  }) async {
    final trimmedRaw = rawFileName.trim();
    final trimmedExisting = (existingTitle ?? '').trim();
    if (trimmedRaw.isEmpty && trimmedExisting.isEmpty) return null;

    final geminiKey = await getGeminiApiKey();
    final promptPreset = await getAiPromptPreset();
    if (geminiKey != null) {
      final geminiRes = await _analyzeWithGemini(
        geminiKey,
        trimmedRaw,
        trimmedExisting,
        promptPreset,
      );
      if (geminiRes != null) return geminiRes;
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client
          .postUrl(Uri.parse('https://text.pollinations.ai/openai'))
          .timeout(const Duration(seconds: 12));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'model': 'openai',
          'temperature': 0.1,
          'messages': [
            {
              'role': 'system',
              'content': _buildAiSystemPrompt(promptPreset),
            },
            {
              'role': 'user',
              'content':
                  'Raw filename: $trimmedRaw\nExisting title in editor: $trimmedExisting',
            },
          ],
        }),
      );
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final rawText = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 12));
      final body = jsonDecode(rawText);
      if (body is! Map<String, dynamic>) return null;
      final choices = body['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices.first;
      if (first is! Map) return null;
      final message = first['message'];
      if (message is! Map) return null;
      final content = (message['content'] ?? '').toString();
      return parseAiSuggestionJson(
        content,
        rawFileName: trimmedRaw,
        aiProvider: 'Pollinations AI',
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<SmartFileNameSuggestion?> _smartCorrectViaBotApi(
    TelegramVideoItem item, {
    String? existingTitle,
  }) async {
    final geminiKey = await getGeminiApiKey();
    final promptPreset = await getAiPromptPreset();
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final res = await NetworkService.instance.client
            .post(
              Uri.parse('$baseUrl/api/admin/videos/${item.msgId}/ai-clean'),
              headers: _ownerHeaders,
              body: jsonEncode({
                'file_name': item.fileName,
                if (existingTitle != null && existingTitle.trim().isNotEmpty)
                  'existing_title': existingTitle.trim(),
                if (geminiKey != null && geminiKey.isNotEmpty)
                  'gemini_api_key': geminiKey,
                if (promptPreset != defaultAiPromptPreset)
                  'prompt_preset': promptPreset,
                'tmdb_api_key': AppConstants.apiKey,
              }),
            )
            .timeout(const Duration(seconds: 26));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['ok'] == true && data['suggestion'] is Map) {
            final s = Map<String, dynamic>.from(data['suggestion'] as Map);
            final title = (s['title'] ?? '').toString().trim();
            if (title.isEmpty) continue;
            final cleanTitle = (s['clean_title'] ?? '').toString().trim();
            final year = (s['year'] is int)
                ? s['year'] as int
                : int.tryParse('${s['year']}');
            final season = (s['season'] is int)
                ? s['season'] as int
                : int.tryParse('${s['season']}');
            final episode = (s['episode'] is int)
                ? s['episode'] as int
                : int.tryParse('${s['episode']}');
            final quality = (s['quality'] ?? '').toString().trim();
            final language = (s['language'] ?? '').toString().trim();
            final aiProvider = (s['ai_provider'] ?? 'Bot AI').toString().trim();
            return SmartFileNameSuggestion(
              title: title,
              searchQuery: cleanTitle.isNotEmpty ? cleanTitle : cleanSearchTitle(title),
              year: year,
              quality: quality.isNotEmpty ? quality : null,
              language: language.isNotEmpty ? language : null,
              matchedTmdb: false,
              usedAi: true,
              isSeries: s['is_series'] == true,
              season: season,
              episode: episode,
              aiProvider: aiProvider.isNotEmpty ? aiProvider : 'Bot AI',
            );
          }
        }
      } catch (_) {}
    }
    return null;
  }

  static List<String> _tokenizeTitle(String value) {
    return RegExp(r'[a-z0-9]+')
        .allMatches(value.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
  }

  /// Picks the best matching TMDB result for [queryTitle], scoring title
  /// overlap, release year, and original language, and rejecting results with
  /// zero title token overlap.
  static Map<String, dynamic>? pickBestTmdbMatch(
    List<Map<String, dynamic>> results,
    String queryTitle, {
    int? expectedYear,
    String? expectedLanguage,
  }) {
    final queryTokens = _tokenizeTitle(queryTitle);
    final queryTokenSet = queryTokens.toSet();
    final normQuery = queryTokens.join(' ');
    final expectedLangs = (expectedLanguage ?? '')
        .split(RegExp(r'[,/|]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();

    Map<String, dynamic>? best;
    double bestScore = double.negativeInfinity;

    for (final item in results) {
      final candNames = <String>[
        (item['title'] ?? item['name'] ?? '').toString().trim(),
        (item['original_title'] ?? item['original_name'] ?? '').toString().trim(),
      ].where((s) => s.isNotEmpty).toList();
      if (candNames.isEmpty) continue;

      double bestTitleScore = double.negativeInfinity;
      bool hasOverlap = queryTokenSet.isEmpty;
      for (final candName in candNames) {
        final candTokens = _tokenizeTitle(candName);
        final candTokenSet = candTokens.toSet();
        final overlap = queryTokenSet.intersection(candTokenSet).length;
        if (queryTokenSet.isNotEmpty && overlap == 0) continue;
        hasOverlap = true;
        final normCand = candTokens.join(' ');
        double score =
            overlap * 6.0 - (candTokens.length - queryTokens.length).abs();
        if (normQuery.isNotEmpty && normCand == normQuery) {
          score += 24.0;
        }
        if (queryTokenSet.isNotEmpty &&
            candTokenSet.length == queryTokenSet.length &&
            overlap == queryTokenSet.length) {
          score += 16.0;
        }
        if (score > bestTitleScore) bestTitleScore = score;
      }
      if (!hasOverlap) continue;

      final rd = (item['release_date'] ?? item['first_air_date'] ?? '')
          .toString()
          .trim();
      final candYear = rd.length >= 4 ? int.tryParse(rd.substring(0, 4)) : null;
      double yearScore = 0.0;
      if (expectedYear != null) {
        if (candYear == null) {
          yearScore = 1.0;
        } else if (candYear == expectedYear) {
          yearScore = 10.0;
        } else if ((candYear - expectedYear).abs() == 1) {
          yearScore = 4.0;
        } else {
          yearScore = -4.0;
        }
      }

      double langScore = 0.0;
      if (expectedLangs.isNotEmpty) {
        final mappedLang =
            (mapLanguageCode(item['original_language']?.toString()) ?? '')
                .toLowerCase();
        if (mappedLang.isNotEmpty && expectedLangs.contains(mappedLang)) {
          langScore = expectedLangs.length == 1 ? 8.0 : 5.0;
        }
      }

      final rawPop = double.tryParse('${item['popularity'] ?? 0}') ?? 0.0;
      final popScore = (rawPop > 50.0 ? 50.0 : rawPop) * 0.05;
      final total = bestTitleScore + yearScore + langScore + popScore;
      if (total > bestScore) {
        bestScore = total;
        best = item;
      }
    }

    return best;
  }

  /// Uses the bot backend's full AI + IMDb + audio-metadata pipeline when
  /// [videoItem] is provided (falling back to client-side Gemini/Pollinations/Local),
  /// and matches against TMDB (TV search for series, Movie search for movies).
  Future<SmartFileNameSuggestion> smartCorrectMetadata(
    String rawFileName, {
    String? existingTitle,
    TelegramVideoItem? videoItem,
  }) async {
    SmartFileNameSuggestion? botSuggestion;
    if (videoItem != null) {
      botSuggestion = await _smartCorrectViaBotApi(
        videoItem,
        existingTitle: existingTitle,
      );
    }
    final aiSuggestion = botSuggestion ??
        await analyzeFileNameWithAi(
          rawFileName,
          existingTitle: existingTitle,
        );
    final base = aiSuggestion ??
        analyzeFileNameLocally(
          rawFileName,
          existingTitle: existingTitle,
        );
    if (base.searchQuery.isEmpty) return base;

    List<Map<String, dynamic>> results = const <Map<String, dynamic>>[];
    if (base.isSeries) {
      final tvRes = await searchTmdbTvPage(base.searchQuery, page: 1);
      results = tvRes.shows;
    }
    if (results.isEmpty) {
      final pageRes = await searchTmdbMoviesPage(base.searchQuery, page: 1);
      results = pageRes.movies;
    }
    if (results.isEmpty) return base;

    final best = pickBestTmdbMatch(
      results,
      base.searchQuery,
      expectedYear: base.year,
      expectedLanguage: base.language,
    );
    if (best == null) return base;

    final tmdbId = (best['id'] is int)
        ? best['id'] as int
        : int.tryParse('${best['id']}');
    final tmdbTitle = (best['title'] ?? best['name'] ?? '').toString().trim();
    final tmdbRelease =
        (best['release_date'] ?? best['first_air_date'] ?? '').toString().trim();
    final tmdbYearStr = tmdbRelease.length >= 4 ? tmdbRelease.substring(0, 4) : null;
    final tmdbYearInt = tmdbYearStr != null ? int.tryParse(tmdbYearStr) : null;
    final tmdbOverview = (best['overview'] ?? '').toString().trim();
    final tmdbPoster = (best['poster_path'] ?? '').toString().trim();
    final tmdbOriginalLanguage = mapLanguageCode(
      best['original_language']?.toString(),
    );
    final resolvedLanguage = (base.language != null && base.language!.trim().isNotEmpty)
        ? base.language!.trim()
        : tmdbOriginalLanguage;

    final finalTitle = base.usedAi &&
            (base.language != null && base.language!.trim().isNotEmpty)
        ? base.title
        : (tmdbTitle.isNotEmpty || (base.searchQuery.isNotEmpty)
            ? buildStandardFileName(
                baseTitle: tmdbTitle.isNotEmpty ? tmdbTitle : base.searchQuery,
                year: tmdbYearInt ?? base.year,
                language: resolvedLanguage,
                quality: base.quality,
                season: base.season,
                episode: base.episode,
              )
            : base.title);

    return SmartFileNameSuggestion(
      title: finalTitle,
      searchQuery: base.searchQuery,
      year: tmdbYearInt ?? base.year,
      quality: base.quality,
      language: resolvedLanguage,
      overview: tmdbOverview.isNotEmpty ? tmdbOverview : null,
      tmdbId: tmdbId,
      tmdbTitle: tmdbTitle.isNotEmpty ? tmdbTitle : null,
      tmdbPoster: tmdbPoster.isNotEmpty ? tmdbPoster : null,
      tmdbYear: tmdbYearStr,
      matchedTmdb: tmdbId != null,
      usedAi: base.usedAi,
      isSeries: base.isSeries,
      season: base.season,
      episode: base.episode,
      aiProvider: base.aiProvider,
    );
  }

  Future<VideoTracksInspectResult> fetchBotVideoTracks(
    TelegramVideoItem item, {
    bool refresh = false,
  }) async {
    final identifier = item.msgId != null
        ? '${item.msgId}'
        : item.streamCode.trim();
    if (identifier.isEmpty) {
      return const VideoTracksInspectResult(
        ok: false,
        errorMessage: 'Missing video identifier',
      );
    }

    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final uri = Uri.parse(
          '$baseUrl/api/videos/${Uri.encodeComponent(identifier)}/tracks',
        ).replace(queryParameters: refresh ? const {'refresh': '1'} : null);
        final res = await NetworkService.instance.client
            .get(uri)
            .timeout(const Duration(seconds: 22));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map && decoded['ok'] == true) {
            final tracks = (decoded['audio_tracks'] as List? ?? [])
                .whereType<Map>()
                .map((e) => VideoAudioTrackInfo.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            final disabled = (decoded['disabled_audio_indices'] as List? ?? [])
                .map((e) => e is int ? e : int.tryParse(e.toString()))
                .whereType<int>()
                .toList();
            return VideoTracksInspectResult(
              ok: true,
              tracks: tracks,
              disabledAudioIndices: disabled,
            );
          }
        }
      } catch (_) {}
    }
    return VideoTracksInspectResult(
      ok: false,
      tracks: item.audioTracks,
      disabledAudioIndices: item.disabledAudioIndices,
      errorMessage: 'Could not inspect audio tracks from server.',
    );
  }

  Future<TelegramVideoItem?> updateBotVideoMetadata(
    TelegramVideoItem item, {
    String? title,
    int? year,
    bool clearYear = false,
    String? quality,
    String? language,
    String? overview,
    int? tmdbId,
    bool clearTmdb = false,
    String? tmdbTitle,
    String? tmdbPoster,
    String? tmdbYear,
    bool? hiddenForUsers,
    List<int>? disabledAudioIndices,
    List<VideoAudioTrackInfo>? audioTracks,
  }) async {
    final identifier = item.msgId != null
        ? '${item.msgId}'
        : item.streamCode.trim();
    if (identifier.isEmpty) return null;

    final body = <String, dynamic>{};
    if (title != null) body['title'] = title.trim();
    if (clearYear) {
      body['year'] = null;
    } else if (year != null) {
      body['year'] = year;
    }
    if (quality != null) body['quality'] = quality.trim();
    if (language != null) body['language'] = language.trim();
    if (overview != null) body['overview'] = overview.trim();
    if (clearTmdb) {
      body['tmdb_id'] = null;
    } else if (tmdbId != null) {
      body['tmdb_id'] = tmdbId;
      if (tmdbTitle != null) body['tmdb_title'] = tmdbTitle;
      if (tmdbPoster != null) body['tmdb_poster'] = tmdbPoster;
      if (tmdbYear != null) body['tmdb_year'] = tmdbYear;
    }
    if (hiddenForUsers != null) {
      body['hidden_for_users'] = hiddenForUsers;
    }
    if (disabledAudioIndices != null) {
      body['disabled_audio_indices'] = disabledAudioIndices;
    }
    if (audioTracks != null) {
      body['audio_tracks'] = audioTracks.map((t) => t.toJson()).toList();
    }

    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final uri = Uri.parse(
          '$baseUrl/api/admin/videos/${Uri.encodeComponent(identifier)}',
        );
        final res = await NetworkService.instance.client
            .patch(uri, headers: _ownerHeaders, body: jsonEncode(body))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map &&
              decoded['ok'] == true &&
              decoded['video'] is Map) {
            final updated = TelegramVideoItem.fromJson(
              Map<String, dynamic>.from(decoded['video'] as Map),
              fallbackBaseUrl: baseUrl,
            );
            await _syncSavedItemIfPresent(updated);
            return updated;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> _syncSavedItemIfPresent(TelegramVideoItem updated) async {
    try {
      final saved = await getSavedManualVideos();
      final idx = saved.indexWhere(
        (s) =>
            s.streamUrl.trim() == updated.streamUrl.trim() ||
            (updated.msgId != null && s.msgId == updated.msgId),
      );
      if (idx >= 0) {
        saved[idx] = updated;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefSavedUrlsKey,
          jsonEncode(saved.map((e) => e.toJson()).toList()),
        );
      }
    } catch (_) {}
  }

  /// Searches TMDB movies DB so users can browse movies alongside bot files.
  Future<List<Map<String, dynamic>>> searchTmdbMovies(String query) async {
    final pageRes = await searchTmdbMoviesPage(query, page: 1);
    return pageRes.movies.take(15).toList();
  }

  /// Paginated TMDB movie search used by collection picker scrolling.
  Future<({List<Map<String, dynamic>> movies, bool hasMore})>
      searchTmdbMoviesPage(String query, {int page = 1}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return (movies: const <Map<String, dynamic>>[], hasMore: false);
    try {
      final data = await NetworkService.instance.getTmdbJson(
        '/3/search/movie?api_key=${AppConstants.apiKey}&query=${Uri.encodeComponent(trimmed)}&page=$page',
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
        }
        final totalPages = (data['total_pages'] as num?)?.toInt() ?? 1;
        return (movies: unique, hasMore: page < totalPages);
      }
    } catch (_) {}
    return (movies: const <Map<String, dynamic>>[], hasMore: false);
  }

  /// Paginated TMDB TV series search used when AI detects a series/episode.
  Future<({List<Map<String, dynamic>> shows, bool hasMore})> searchTmdbTvPage(
    String query, {
    int page = 1,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return (shows: const <Map<String, dynamic>>[], hasMore: false);
    }
    try {
      final data = await NetworkService.instance.getTmdbJson(
        '/3/search/tv?api_key=${AppConstants.apiKey}&query=${Uri.encodeComponent(trimmed)}&page=$page',
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
        }
        final totalPages = (data['total_pages'] as num?)?.toInt() ?? 1;
        return (shows: unique, hasMore: page < totalPages);
      }
    } catch (_) {}
    return (shows: const <Map<String, dynamic>>[], hasMore: false);
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

  Future<BotBroadcastResult> sendBotBroadcast(
    String message, {
    List<BroadcastButton> buttons = const [],
    String parseMode = 'markdown',
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return const BotBroadcastResult(ok: false, error: 'Message cannot be empty');
    }
    final payload = <String, dynamic>{
      'message': trimmed,
      'parse_mode': parseMode,
      if (buttons.isNotEmpty)
        'buttons': buttons.map((b) => b.toJson()).toList(),
    };
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final res = await NetworkService.instance.client
            .post(
              Uri.parse('$baseUrl/api/admin/broadcast'),
              headers: _ownerHeaders,
              body: jsonEncode(payload),
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

  /// Clears all saved video and thumbnail documents from the bot's MongoDB.
  Future<BotDbClearResult> clearBotVideosDb() async {
    for (final baseUrl in await _candidateBaseUrls()) {
      try {
        final res = await NetworkService.instance.client
            .delete(
              Uri.parse('$baseUrl/api/admin/videos'),
              headers: _ownerHeaders,
            )
            .timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['ok'] == true) {
            return BotDbClearResult(
              ok: true,
              deletedVideos: (data['deleted_videos'] as num?)?.toInt() ?? 0,
              deletedThumbnails:
                  (data['deleted_thumbnails'] as num?)?.toInt() ?? 0,
            );
          }
        }
        if (res.statusCode == 403) {
          return const BotDbClearResult(
            ok: false,
            errorMessage: 'Unauthorized (owner key mismatch).',
          );
        }
      } catch (_) {}
    }
    return const BotDbClearResult(
      ok: false,
      errorMessage: 'Could not reach bot admin API.',
    );
  }
}

class BotDbClearResult {
  final bool ok;
  final int deletedVideos;
  final int deletedThumbnails;
  final String? errorMessage;

  const BotDbClearResult({
    required this.ok,
    this.deletedVideos = 0,
    this.deletedThumbnails = 0,
    this.errorMessage,
  });
}

class SmartFileNameSuggestion {
  final String title;
  final String searchQuery;
  final int? year;
  final String? quality;
  final String? language;
  final String? overview;
  final int? tmdbId;
  final String? tmdbTitle;
  final String? tmdbPoster;
  final String? tmdbYear;
  final bool matchedTmdb;
  final bool usedAi;
  final bool isSeries;
  final int? season;
  final int? episode;
  final String aiProvider;

  const SmartFileNameSuggestion({
    required this.title,
    required this.searchQuery,
    this.year,
    this.quality,
    this.language,
    this.overview,
    this.tmdbId,
    this.tmdbTitle,
    this.tmdbPoster,
    this.tmdbYear,
    this.matchedTmdb = false,
    this.usedAi = false,
    this.isSeries = false,
    this.season,
    this.episode,
    this.aiProvider = 'Local',
  });
}

class BroadcastButton {
  final String text;
  final String url;
  final int row;

  const BroadcastButton({
    required this.text,
    required this.url,
    this.row = 0,
  });

  Map<String, dynamic> toJson() => {'text': text, 'url': url, 'row': row};
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
