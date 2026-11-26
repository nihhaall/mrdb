import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mrdb/services/telegram_stream_service.dart';

typedef VideoFrameExtractor = Future<Uint8List?> Function(String streamUrl);
typedef SaveVideoFrameFn = Future<String?> Function(String key, Uint8List bytes);

/// Extracts and caches a real JPEG frame from streamed video files whenever
/// a server thumbnail is unavailable.
class VideoFrameThumbnailService extends ChangeNotifier {
  VideoFrameThumbnailService._({
    VideoFrameExtractor? primaryExtractor,
    VideoFrameExtractor? fallbackExtractor,
    SaveVideoFrameFn? saveFrame,
  })  : _primaryExtractor = primaryExtractor ?? _defaultAndroidExtractor,
        _fallbackExtractor = fallbackExtractor ?? _defaultMediaKitExtractor,
        _saveFrame = saveFrame ?? TelegramStreamService.instance.saveCapturedFrame;

  @visibleForTesting
  factory VideoFrameThumbnailService.forTest({
    required VideoFrameExtractor primaryExtractor,
    VideoFrameExtractor? fallbackExtractor,
    SaveVideoFrameFn? saveFrame,
  }) {
    return VideoFrameThumbnailService._(
      primaryExtractor: primaryExtractor,
      fallbackExtractor: fallbackExtractor ?? (_) async => null,
      saveFrame: saveFrame ?? (_, _) async => null,
    );
  }

  static final VideoFrameThumbnailService instance =
      VideoFrameThumbnailService._();

  static const MethodChannel _channel =
      MethodChannel('com.mrdb.flit/video_thumbnail');
  static const int _maxConcurrent = 2;

  final VideoFrameExtractor _primaryExtractor;
  final VideoFrameExtractor _fallbackExtractor;
  final SaveVideoFrameFn _saveFrame;

  final Map<String, String> _cachedPaths = {};
  final Set<String> _inFlightKeys = {};
  final Set<String> _failedKeys = {};
  final Queue<_FrameJob> _queue = Queue<_FrameJob>();
  int _activeCount = 0;

  Map<String, String> get cachedPaths => Map.unmodifiable(_cachedPaths);

  bool isExtracting(String key) => _inFlightKeys.contains(key);

  String? pathFor(String key) => _cachedPaths[key];

  void clearFailedCache() {
    _failedKeys.clear();
  }

  void requestFrame(TelegramVideoItem item) {
    final key = TelegramStreamService.progressKeyFor(item);
    final url = item.streamUrl.trim();
    if (key.isEmpty || url.isEmpty) return;
    if (_cachedPaths.containsKey(key) ||
        _inFlightKeys.contains(key) ||
        _failedKeys.contains(key)) {
      return;
    }

    _inFlightKeys.add(key);
    _queue.add(_FrameJob(key: key, streamUrl: url));
    notifyListeners();
    _pumpQueue();
  }

  void _pumpQueue() {
    while (_activeCount < _maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _activeCount++;
      unawaited(_runJob(job));
    }
  }

  Future<void> _runJob(_FrameJob job) async {
    try {
      Uint8List? bytes = await _primaryExtractor(job.streamUrl);
      if (bytes == null || bytes.isEmpty) {
        bytes = await _fallbackExtractor(job.streamUrl);
      }

      if (bytes != null && bytes.isNotEmpty) {
        final savedPath = await _saveFrame(job.key, bytes);
        if (savedPath != null && savedPath.isNotEmpty) {
          _cachedPaths[job.key] = savedPath;
        } else {
          _failedKeys.add(job.key);
        }
      } else {
        _failedKeys.add(job.key);
      }
    } catch (_) {
      _failedKeys.add(job.key);
    } finally {
      _inFlightKeys.remove(job.key);
      _activeCount = (_activeCount - 1).clamp(0, _maxConcurrent);
      notifyListeners();
      _pumpQueue();
    }
  }

  static Future<Uint8List?> _defaultAndroidExtractor(String streamUrl) async {
    if (!Platform.isAndroid) return null;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'extractVideoFrame',
        {'url': streamUrl, 'timeMs': 600000},
      );
      return (bytes != null && bytes.isNotEmpty) ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  // Serialized mutex for fallback libmpv extraction so only 1 headless player runs at a time
  static Future<void> _mediaKitMutex = Future.value();

  static Future<Uint8List?> _defaultMediaKitExtractor(String streamUrl) {
    final completer = Completer<Uint8List?>();
    _mediaKitMutex = _mediaKitMutex.then((_) async {
      final atTenMin = await _extractWithMediaKit(
        streamUrl,
        startAt: const Duration(minutes: 10),
      );
      if (atTenMin != null && atTenMin.isNotEmpty) {
        completer.complete(atTenMin);
        return;
      }
      // Fallback for clips shorter than 10 minutes
      final shortFallback = await _extractWithMediaKit(
        streamUrl,
        startAt: const Duration(seconds: 5),
      );
      completer.complete(shortFallback);
    }).catchError((_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future;
  }

  static Future<Uint8List?> _extractWithMediaKit(
    String streamUrl, {
    required Duration startAt,
  }) async {
    Player? player;
    final subs = <StreamSubscription<dynamic>>[];
    try {
      player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 4 * 1024 * 1024,
        ),
      );
      // Attach VideoController so libmpv initializes a video output for screenshot()
      // ignore: unused_local_variable
      final controller = VideoController(player);

      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        await Future.wait([
          native.setProperty('aid', 'no'),
          native.setProperty('sid', 'no'),
          native.setProperty('mute', 'yes'),
          native.setProperty('hr-seek', 'no'),
          native.setProperty('demuxer-lavf-probesize', '250000'),
          native.setProperty('demuxer-lavf-analyzeduration', '0.5'),
        ]);
      }

      final frameReady = Completer<void>();
      subs.add(
        player.stream.videoParams.listen((params) {
          if (!frameReady.isCompleted &&
              (params.w ?? 0) > 0 &&
              (params.h ?? 0) > 0) {
            frameReady.complete();
          }
        }),
      );

      await player.open(
        Media(streamUrl, start: startAt),
        play: true,
      );

      await frameReady.future.timeout(const Duration(seconds: 12));
      await Future.delayed(const Duration(milliseconds: 220));
      await player.pause();

      final bytes = await player.screenshot(format: 'image/jpeg');
      return (bytes != null && bytes.isNotEmpty) ? bytes : null;
    } catch (_) {
      return null;
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      await player?.dispose();
    }
  }
}

class _FrameJob {
  final String key;
  final String streamUrl;

  const _FrameJob({required this.key, required this.streamUrl});
}
