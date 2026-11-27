import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mrdb/services/app_update_service.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/services/stream_proxy_service.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/services/video_frame_thumbnail_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Fullscreen landscape `.mkv` / `.mp4` streaming player powered by `media_kit`
/// (`libmpv`), supporting HTTP byte-range seeking, multi-audio tracks, and
/// embedded subtitles.
class MkvStreamPlayerPage extends StatefulWidget {
  final String title;
  final String streamUrl;
  final String? fallbackWebUrl;
  final String? formatLabel;
  final String? progressKey;
  final Duration? initialPosition;
  final String? thumbnailUrl;
  final String? thumbnailPath;
  final List<int> disabledAudioIndices;

  const MkvStreamPlayerPage({
    super.key,
    required this.title,
    required this.streamUrl,
    this.fallbackWebUrl,
    this.formatLabel,
    this.progressKey,
    this.initialPosition,
    this.thumbnailUrl,
    this.thumbnailPath,
    this.disabledAudioIndices = const [],
  });

  @override
  State<MkvStreamPlayerPage> createState() => _MkvStreamPlayerPageState();
}

class _MkvStreamPlayerPageState extends State<MkvStreamPlayerPage> {
  static const Color _kAccent = Color(0xFF00E5A0);

  Player? _player;
  VideoController? _videoController;

  bool _showControls = true;
  bool _isSeekingSlider = false;
  double _sliderValueMs = 0;
  bool _showForwardIndicator = false;
  bool _showRewindIndicator = false;
  bool _showCenterPlayPauseIndicator = false;
  bool _centerIndicatorPlaying = false;
  bool _isLongPressSpeed = false;
  double _rateBeforeLongPress = 1.0;
  BoxFit _videoFit = BoxFit.contain;
  int? _selectedScaleHeight;
  String? _errorMessage;

  static const MethodChannel _controlsChannel = MethodChannel(
    'com.mrdb.flit/player_controls',
  );
  static const EventChannel _networkChannel = EventChannel(
    'com.mrdb.flit/player_network',
  );
  final StreamProxyService _streamProxy = StreamProxyService();
  bool _wasOffline = false;
  bool _recoveringConnection = false;
  String _lastTransport = '';
  Duration _lastKnownPosition = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  Duration _streamBaseOffset = Duration.zero;
  Duration _knownDuration = Duration.zero;
  int? _activeTranscodeHeight;
  int? _originalHeight;
  DateTime? _stallStartedAt;
  Timer? _stallWatchdogTimer;
  StreamSubscription<dynamic>? _networkSub;

  double _brightness = 0.5;
  double _volume = 1.0;
  String? _activeDragType; // 'brightness' or 'volume'
  double _dragStartValue = 0.5;
  double _dragStartY = 0;
  bool _didInitialFrameCapture = false;
  bool _capturingFrame = false;
  bool _didExitCapture = false;
  bool _appliedInitialAudioFilter = false;
  bool _hasSurfaceFrame = false;
  bool _applied4kSwTuning = false;
  bool _hasFirstFrame = false;
  String? _resolvedThumbPath;
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  String get _effectiveProgressKey {
    final pk = widget.progressKey?.trim() ?? '';
    if (pk.isNotEmpty) return pk;
    return widget.streamUrl.trim();
  }

  static final RegExp _trailingExtRegex = RegExp(
    r'\.(mkv|mp4|avi|mov|webm|m4v|ts|flv)$',
    caseSensitive: false,
  );

  String _cleanTitle(String raw) => raw.replaceFirst(_trailingExtRegex, '').trim();

  Timer? _hideTimer;
  Timer? _indicatorTimer;
  Timer? _centerIndicatorTimer;
  Timer? _dragHideTimer;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _lastKnownPosition = widget.initialPosition ?? Duration.zero;
    _initLocalThumbnail();
    NetworkService.instance.enterPlayerExclusiveMode();
    VideoFrameThumbnailService.instance.setPaused(true);
    AppUpdateService.instance.pauseBackgroundWorkForPlayback();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadDeviceLevels();
    _initPlayerPerformanceAndNetwork();
    _startStallWatchdog();
    _initAndOpen();
  }

  void _initLocalThumbnail() {
    final direct = widget.thumbnailPath?.trim();
    if (direct != null && direct.isNotEmpty && File(direct).existsSync()) {
      _resolvedThumbPath = direct;
      return;
    }
    final cached = VideoFrameThumbnailService.instance.pathFor(
      _effectiveProgressKey,
    );
    if (cached != null && cached.isNotEmpty && File(cached).existsSync()) {
      _resolvedThumbPath = cached;
      return;
    }
    unawaited(_resolveSavedThumbnail());
  }

  Future<void> _resolveSavedThumbnail() async {
    final frames = await TelegramStreamService.instance.getAllCapturedFrames();
    final path = frames[_effectiveProgressKey];
    if (!mounted || _hasFirstFrame) return;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      setState(() => _resolvedThumbPath = path);
    }
  }

  void _startStallWatchdog() {
    _stallWatchdogTimer?.cancel();
    _stallWatchdogTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted) return;
      final p = _player;
      final buffering = p?.state.buffering ?? false;
      final net = _streamProxy.stats.value;
      final hasBufferedAhead =
          _bufferedPosition > _effectivePosition + const Duration(seconds: 1);
      if (!buffering ||
          hasBufferedAhead ||
          net.phase == StreamConnectionPhase.offline ||
          net.phase == StreamConnectionPhase.retrying) {
        _stallStartedAt = null;
        return;
      }
      if (net.bytesPerSecond > 1024) {
        _stallStartedAt = null;
        return;
      }
      _stallStartedAt ??= DateTime.now();
      if (DateTime.now().difference(_stallStartedAt!).inSeconds >= 30 &&
          !_recoveringConnection) {
        _stallStartedAt = null;
        unawaited(_recoverStreamConnection());
      }
    });
  }

  Future<void> _initPlayerPerformanceAndNetwork() async {
    try {
      final transport = await _controlsChannel.invokeMethod<String>(
        'setPlayerPerformanceMode',
        {'enabled': true},
      );
      if (transport != null && transport.trim().isNotEmpty) {
        _lastTransport = transport.trim();
        _wasOffline = _lastTransport.toLowerCase() == 'offline';
        _streamProxy.setTransportLabel(_lastTransport);
      }
    } catch (_) {
      // Ignore on unsupported platforms or test environments.
    }

    try {
      _networkSub = _networkChannel.receiveBroadcastStream().listen((event) {
        if (!mounted || event == null) return;
        final label = event.toString().trim();
        if (label.isEmpty) return;
        final isOffline = label.toLowerCase() == 'offline';
        final networkRestored = _wasOffline && !isOffline;
        final networkSwitched =
            !isOffline && _lastTransport.isNotEmpty && _lastTransport != label;
        _wasOffline = isOffline;
        _lastTransport = label;
        _streamProxy.setTransportLabel(label);

        if ((networkRestored || networkSwitched) &&
            (_errorMessage != null || (_player?.state.buffering ?? false))) {
          unawaited(_recoverStreamConnection());
        }
      }, onError: (_) {});
    } catch (_) {
      // Ignore if event channel is unavailable in tests.
    }
  }

  Future<void> _recoverStreamConnection() async {
    if (!mounted || _recoveringConnection) return;
    _recoveringConnection = true;
    try {
      await _initAndOpen();
    } finally {
      _recoveringConnection = false;
    }
  }

  String? _buildTranscodeUrl(int height, int startSeconds) {
    final uri = Uri.tryParse(widget.streamUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    int? msgId;
    String? hash = uri.queryParameters['hash']?.trim();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length >= 2) {
      msgId = int.tryParse(segments[0]);
    } else if (segments.length == 1) {
      final m = RegExp(r'^([a-zA-Z0-9_-]{6})(\d+)$').firstMatch(segments[0]);
      if (m != null) {
        hash = m.group(1);
        msgId = int.tryParse(m.group(2)!);
      }
    }
    if (msgId == null || hash == null || hash.isEmpty) return null;
    final portPart = uri.hasPort ? ':${uri.port}' : '';
    final sec = math.max(0, startSeconds);
    return '${uri.scheme}://${uri.host}$portPart/transcode/$msgId/${height}p?hash=${Uri.encodeQueryComponent(hash)}&ss=$sec';
  }

  Future<void> _loadDeviceLevels() async {
    try {
      final b = await _controlsChannel.invokeMethod<double>('getBrightness');
      final v = await _controlsChannel.invokeMethod<double>('getVolume');
      if (mounted) {
        setState(() {
          if (b != null) _brightness = b.clamp(0.01, 1.0);
          if (v != null) _volume = v.clamp(0.0, 1.0);
        });
      }
    } catch (_) {
      // Ignore on unsupported platforms or test environments.
    }
  }

  Future<void> _initAndOpen() async {
    setState(() {
      _errorMessage = null;
      _hasSurfaceFrame = false;
      _hasFirstFrame = false;
      _applied4kSwTuning = false;
    });
    try {
      MediaKit.ensureInitialized();
      if (_player == null) {
        final p = Player(
          configuration: PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
            logLevel: kDebugMode ? MPVLogLevel.warn : MPVLogLevel.error,
          ),
        );
        final vc = VideoController(
          p,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
            hwdec: 'mediacodec,mediacodec-copy,auto-safe',
          ),
        );
        _player = p;
        _videoController = vc;
        // Wait for VideoController platform init so AndroidVideoController.create
        // does not overwrite hwdec back to 'auto-safe'.
        try {
          await vc.platform.future.timeout(const Duration(seconds: 3));
        } catch (_) {}
        if (kDebugMode) {
          _subs.add(
            p.stream.log.listen((entry) {
              debugPrint('[mpv ${entry.level}] ${entry.prefix}: ${entry.text}');
            }),
          );
        }
        vc.waitUntilFirstFrameRendered.then((_) {
          if (!mounted) return;
          _hasSurfaceFrame = true;
          if (!p.state.buffering && p.state.position > Duration.zero) {
            setState(() => _hasFirstFrame = true);
          }
        });

        _subs.add(
          p.stream.error.listen((msg) {
            if (!mounted || msg.trim().isEmpty) return;
            // Ignore transient/non-fatal mpv warnings while video is playing
            if (p.state.playing) return;
            setState(() {
              _errorMessage = msg;
              _showControls = true;
            });
          }),
        );
        _subs.add(
          p.stream.playing.listen((playing) {
            if (!mounted) return;
            setState(() {
              if (playing) {
                _errorMessage = null;
              }
            });
            if (playing) {
              _scheduleHideControls();
            } else {
              _hideTimer?.cancel();
              if (_hasSurfaceFrame &&
                  _effectivePosition >= const Duration(seconds: 3)) {
                unawaited(_captureFrameNow(asLastFrame: true));
              }
            }
          }),
        );
        _subs.add(
          p.stream.position.listen((rawPos) {
            if (!mounted || _isSeekingSlider) return;
            final effectivePos = _streamBaseOffset + rawPos;
            if (effectivePos > Duration.zero) {
              _lastKnownPosition = effectivePos;
            }
            final shouldRevealFirstFrame =
                !_hasFirstFrame &&
                _hasSurfaceFrame &&
                !p.state.buffering &&
                rawPos > Duration.zero;
            setState(() {
              _sliderValueMs = effectivePos.inMilliseconds.toDouble();
              if (rawPos > Duration.zero && _errorMessage != null) {
                _errorMessage = null;
              }
              if (shouldRevealFirstFrame) {
                _hasFirstFrame = true;
              }
            });
            final now = DateTime.now();
            if (effectivePos >= const Duration(minutes: 10) &&
                !_didInitialFrameCapture) {
              _didInitialFrameCapture = true;
              unawaited(_captureFrameNow());
            }
            if (now.difference(_lastProgressSave).inSeconds >= 5) {
              _lastProgressSave = now;
              _saveProgressNow();
            }
          }),
        );
        _subs.add(
          p.stream.buffering.listen((buffering) {
            if (!buffering) _stallStartedAt = null;
            if (buffering && _isLongPressSpeed) {
              unawaited(_endLongPressSpeed());
            }
            if (mounted) {
              setState(() {
                if (!buffering && _hasSurfaceFrame && p.state.position > Duration.zero) {
                  _hasFirstFrame = true;
                }
              });
            }
          }),
        );
        _subs.add(
          p.stream.playing.listen((playing) {
            if (!playing && _isLongPressSpeed) {
              unawaited(_endLongPressSpeed());
            }
          }),
        );
        _subs.add(
          p.stream.buffer.listen((rawBuf) {
            if (!mounted) return;
            setState(() => _bufferedPosition = _streamBaseOffset + rawBuf);
          }),
        );
        _subs.add(
          p.stream.duration.listen((rawDur) {
            if (rawDur > Duration.zero) {
              final candidate = _streamBaseOffset + rawDur;
              if (_activeTranscodeHeight == null || candidate > _knownDuration) {
                _knownDuration = candidate;
              }
            }
            if (_activeTranscodeHeight == null &&
                (p.state.height ?? 0) > 0 &&
                _originalHeight == null) {
              _originalHeight = p.state.height;
              if ((_originalHeight ?? 0) >= 1800) {
                unawaited(_applyAuto4kDecodeGuard());
              }
            }
            if (mounted) setState(() {});
          }),
        );
        _subs.add(
          p.stream.tracks.listen((_) {
            if (_activeTranscodeHeight == null) {
              final h = p.state.height ?? p.state.track.video.h;
              if (h != null && h > 0) {
                _originalHeight ??= h;
              }
            }
            if (!_appliedInitialAudioFilter &&
                widget.disabledAudioIndices.isNotEmpty) {
              final rawAudio = p.state.tracks.audio
                  .where((t) => t.id != 'auto' && t.id != 'no')
                  .toList();
              if (rawAudio.isNotEmpty) {
                final enabledTracks = <AudioTrack>[];
                for (var i = 0; i < rawAudio.length; i++) {
                  if (!widget.disabledAudioIndices.contains(i)) {
                    enabledTracks.add(rawAudio[i]);
                  }
                }
                if (enabledTracks.isNotEmpty) {
                  final activeId = p.state.track.audio.id;
                  final activeIdx = activeId == 'auto'
                      ? 0
                      : rawAudio.indexWhere((t) => t.id == activeId);
                  if (activeIdx >= 0 &&
                      widget.disabledAudioIndices.contains(activeIdx)) {
                    unawaited(p.setAudioTrack(enabledTracks.first));
                  }
                  _appliedInitialAudioFilter = true;
                }
              }
            }
            if (mounted) setState(() {});
          }),
        );
        _subs.add(
          p.stream.videoParams.listen((vp) {
            if (_activeTranscodeHeight == null) {
              final h = vp.dh ?? vp.h;
              if (h != null && h > 0 && _originalHeight == null) {
                if (mounted) {
                  setState(() => _originalHeight = h);
                } else {
                  _originalHeight = h;
                }
                if (h >= 1800) {
                  unawaited(_applyAuto4kDecodeGuard());
                }
              }
            }
          }),
        );
      } else {
        _videoController?.waitUntilFirstFrameRendered.then((_) {
          if (!mounted) return;
          _hasSurfaceFrame = true;
          final p = _player;
          if (p != null && !p.state.buffering && p.state.position > Duration.zero) {
            setState(() => _hasFirstFrame = true);
          }
        });
      }

      if (_player!.platform is NativePlayer) {
        final native = _player!.platform as NativePlayer;
        await _configureNativePlayerProperties(
          native,
          scaleHeight: _activeTranscodeHeight != null ? null : _selectedScaleHeight,
          forceHwCheck: false,
        );
      }

      String targetUpstreamUrl = widget.streamUrl;
      Duration? openStart = _lastKnownPosition > Duration.zero
          ? _lastKnownPosition
          : null;

      if (_activeTranscodeHeight != null) {
        final seekSec = _lastKnownPosition.inSeconds;
        final transcoded = _buildTranscodeUrl(_activeTranscodeHeight!, seekSec);
        if (transcoded != null) {
          _streamBaseOffset = Duration(seconds: seekSec);
          targetUpstreamUrl = transcoded;
          openStart = null; // Server transcode already starts at ?ss=<seekSec>
        } else {
          _activeTranscodeHeight = null;
          _streamBaseOffset = Duration.zero;
        }
      } else {
        _streamBaseOffset = Duration.zero;
      }

      final playbackUrl = await _streamProxy.start(targetUpstreamUrl);
      if (!mounted) return;

      setState(() {});
      await _player!.open(
        Media(playbackUrl, start: openStart),
        play: true,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Player failed to initialize ($e). Perform a full rebuild or try Open Link.';
          _showControls = true;
        });
      }
    }
  }

  Future<void> _captureFrameNow({bool asLastFrame = false}) async {
    final p = _player;
    if (p == null || _capturingFrame || !_hasSurfaceFrame) return;
    _capturingFrame = true;
    try {
      final bytes = await p.screenshot(format: 'image/jpeg');
      if (bytes != null && bytes.isNotEmpty) {
        final key = _effectiveProgressKey;
        if (asLastFrame) {
          await TelegramStreamService.instance.saveLastFrame(key, bytes);
          if (VideoFrameThumbnailService.instance.pathFor(key) == null) {
            await TelegramStreamService.instance.saveCapturedFrame(key, bytes);
          }
        } else {
          await TelegramStreamService.instance.saveCapturedFrame(key, bytes);
        }
      }
    } catch (_) {
    } finally {
      _capturingFrame = false;
    }
  }

  Duration get _effectivePosition =>
      _streamBaseOffset + (_player?.state.position ?? Duration.zero);

  Duration get _effectiveDuration {
    final pDur = _player?.state.duration ?? Duration.zero;
    final combined = _streamBaseOffset + pDur;
    if (_activeTranscodeHeight != null && _knownDuration > combined) {
      return _knownDuration;
    }
    return combined > _knownDuration ? combined : _knownDuration;
  }

  Future<void> _saveProgressNow() async {
    final p = _player;
    if (p == null) return;
    final key = (widget.progressKey?.trim().isNotEmpty ?? false)
        ? widget.progressKey!.trim()
        : widget.streamUrl.trim();
    final pos = _lastKnownPosition > _effectivePosition
        ? _lastKnownPosition
        : _effectivePosition;
    await TelegramStreamService.instance.saveWatchProgress(
      key,
      pos,
      _effectiveDuration,
    );
  }

  @override
  void dispose() {
    final p = _player;
    if (!_didExitCapture &&
        p != null &&
        _hasSurfaceFrame &&
        _effectivePosition >= const Duration(seconds: 3)) {
      _captureFrameNow(asLastFrame: true);
    }
    _saveProgressNow();
    _hideTimer?.cancel();
    _indicatorTimer?.cancel();
    _centerIndicatorTimer?.cancel();
    _dragHideTimer?.cancel();
    _stallWatchdogTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _networkSub?.cancel();
    unawaited(_streamProxy.dispose());
    _player?.dispose();
    VideoFrameThumbnailService.instance.setPaused(false);
    NetworkService.instance.exitPlayerExclusiveMode();
    _controlsChannel
        .invokeMethod<void>('setPlayerPerformanceMode', {'enabled': false})
        .then((_) {}, onError: (_) {});
    _controlsChannel
        .invokeMethod<void>('setBrightness', {'value': -1.0})
        .then((_) {}, onError: (_) {});
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _exitPlayer() async {
    if (!_didExitCapture) {
      _didExitCapture = true;
      final p = _player;
      if (p != null &&
          _hasSurfaceFrame &&
          _effectivePosition >= const Duration(seconds: 3)) {
        await _captureFrameNow(asLastFrame: true)
            .timeout(const Duration(milliseconds: 600), onTimeout: () {});
      }
    }
    await _saveProgressNow();
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          (_player?.state.playing ?? false) &&
          !_isSeekingSlider) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls && (_player?.state.playing ?? false)) {
      _scheduleHideControls();
    }
  }

  Future<void> _seekToEffective(Duration target) async {
    final p = _player;
    if (p == null) return;
    var next = target;
    if (next < Duration.zero) next = Duration.zero;
    final total = _effectiveDuration;
    if (total > Duration.zero && next > total) next = total;
    _lastKnownPosition = next;
    _sliderValueMs = next.inMilliseconds.toDouble();

    if (_activeTranscodeHeight != null) {
      _streamBaseOffset = Duration(seconds: next.inSeconds);
      await _initAndOpen();
    } else {
      await p.seek(next);
    }
  }

  void _seekRelative(int seconds) {
    final p = _player;
    if (p == null) return;
    final current = _effectivePosition;
    unawaited(_seekToEffective(current + Duration(seconds: seconds)));

    _indicatorTimer?.cancel();
    setState(() {
      _showForwardIndicator = seconds > 0;
      _showRewindIndicator = seconds < 0;
    });
    _indicatorTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _showForwardIndicator = false;
          _showRewindIndicator = false;
        });
      }
    });
  }

  String _formatDuration(Duration d) {
    final totalSec = d.inSeconds.clamp(0, 864000);
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  String _trackLabel(dynamic track, int idx) {
    final title = (track.title ?? '').toString().trim();
    final lang = (track.language ?? '').toString().trim();
    final codec = (track.codec ?? '').toString().trim();
    final parts = <String>[
      if (title.isNotEmpty) title,
      if (lang.isNotEmpty) lang.toUpperCase(),
      if (codec.isNotEmpty) codec.toUpperCase(),
    ];
    if (parts.isEmpty) return 'Track $idx';
    return parts.join(' • ');
  }

  Future<void> _showAudioTracksSheet() async {
    final p = _player;
    if (p == null) return;
    final allTracks = p.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final visibleEntries = <({int index, AudioTrack track})>[];
    for (var i = 0; i < allTracks.length; i++) {
      if (!widget.disabledAudioIndices.contains(i)) {
        visibleEntries.add((index: i, track: allTracks[i]));
      }
    }
    final fallbackEntries = visibleEntries.isNotEmpty
        ? visibleEntries
        : [
            for (var i = 0; i < allTracks.length; i++)
              (index: i, track: allTracks[i]),
          ];
    final current = p.state.track.audio;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141724),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Text(
                'Audio Track',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.auto_awesome_rounded,
                color: current.id == 'auto' ? _kAccent : Colors.white54,
              ),
              title: const Text(
                'Auto (Default)',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              trailing: current.id == 'auto'
                  ? const Icon(Icons.check_rounded, color: _kAccent)
                  : null,
              onTap: () {
                if (widget.disabledAudioIndices.contains(0) &&
                    fallbackEntries.isNotEmpty) {
                  p.setAudioTrack(fallbackEntries.first.track);
                } else {
                  p.setAudioTrack(AudioTrack.auto());
                }
                Navigator.pop(ctx);
              },
            ),
            for (var i = 0; i < fallbackEntries.length; i++)
              ListTile(
                leading: Icon(
                  Icons.audiotrack_rounded,
                  color: current.id == fallbackEntries[i].track.id
                      ? _kAccent
                      : Colors.white54,
                ),
                title: Text(
                  _trackLabel(fallbackEntries[i].track, i + 1),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                trailing: current.id == fallbackEntries[i].track.id
                    ? const Icon(Icons.check_rounded, color: _kAccent)
                    : null,
                onTap: () {
                  p.setAudioTrack(fallbackEntries[i].track);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSubtitleTracksSheet() async {
    final p = _player;
    if (p == null) return;
    final tracks = p.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final current = p.state.track.subtitle;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141724),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Text(
                'Subtitles',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.subtitles_off_rounded,
                color: current.id == 'no' ? _kAccent : Colors.white54,
              ),
              title: const Text(
                'Off',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              trailing: current.id == 'no'
                  ? const Icon(Icons.check_rounded, color: _kAccent)
                  : null,
              onTap: () {
                p.setSubtitleTrack(SubtitleTrack.no());
                Navigator.pop(ctx);
              },
            ),
            for (var i = 0; i < tracks.length; i++)
              ListTile(
                leading: Icon(
                  Icons.subtitles_rounded,
                  color: current.id == tracks[i].id ? _kAccent : Colors.white54,
                ),
                title: Text(
                  _trackLabel(tracks[i], i + 1),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                trailing: current.id == tracks[i].id
                    ? const Icon(Icons.check_rounded, color: _kAccent)
                    : null,
                onTap: () {
                  p.setSubtitleTrack(tracks[i]);
                  Navigator.pop(ctx);
                },
              ),
            if (tracks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Text(
                  'No embedded subtitle tracks detected in this file.',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _configureNativePlayerProperties(
    NativePlayer native, {
    int? scaleHeight,
    bool forceHwCheck = true,
  }) async {
    final dataSaver = scaleHeight != null;
    var isSwDecode = false;
    if (forceHwCheck) {
      try {
        final curHw = (await native.getProperty('hwdec-current')).trim();
        isSwDecode = curHw.isEmpty || curHw == 'no';
      } catch (_) {
        isSwDecode = false;
      }
    }
    final useSwVfScale = scaleHeight != null && isSwDecode;

    await Future.wait([
      native.setProperty('cache', 'yes'),
      native.setProperty('cache-on-disk', 'no'),
      native.setProperty('demuxer-max-bytes', dataSaver ? '24MiB' : '48MiB'),
      native.setProperty('demuxer-max-back-bytes', dataSaver ? '12MiB' : '16MiB'),
      native.setProperty('demuxer-readahead-secs', dataSaver ? '30' : '45'),
      native.setProperty('demuxer-lavf-probesize', '1000000'),
      native.setProperty('demuxer-lavf-analyzeduration', '1.2'),
      native.setProperty('cache-pause', 'yes'),
      native.setProperty('cache-pause-initial', 'yes'),
      native.setProperty('cache-pause-wait', '1'),
      native.setProperty('network-timeout', '25'),
      native.setProperty('hr-seek', 'no'),
      native.setProperty('framedrop', 'decoder+vo'),
      native.setProperty('video-sync', 'audio'),
      native.setProperty('initial-audio-sync', 'yes'),
      native.setProperty('audio-pitch-correction', 'yes'),
      native.setProperty('vd-lavc-threads', '0'),
      native.setProperty('ad-lavc-threads', '0'),
      native.setProperty('vd-lavc-fast', 'yes'),
      native.setProperty(
        'vd-lavc-skiploopfilter',
        (dataSaver || isSwDecode) ? 'all' : 'nonref',
      ),
      native.setProperty(
        'vd-lavc-framedrop',
        (dataSaver || isSwDecode) ? 'nonref' : 'default',
      ),
      native.setProperty('scale', 'bilinear'),
      native.setProperty('cscale', 'bilinear'),
      native.setProperty('dscale', 'bilinear'),
      native.setProperty('dither-depth', 'no'),
      native.setProperty('correct-downscaling', 'no'),
      native.setProperty('linear-downscaling', 'no'),
      native.setProperty('hwdec-codecs', 'all'),
      native.setProperty('hwdec', 'mediacodec,mediacodec-copy,auto-safe'),
      native.setProperty(
        'vf',
        useSwVfScale
            ? 'format=yuv420p,scale=-2:$scaleHeight:flags=fast_bilinear'
            : '',
      ),
      native.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2,tcp_nodelay=1,rw_timeout=25000000',
      ),
    ]);
  }

  /// Automatically engages fast software-decode tuning if a 4K+ stream could not
  /// attach hardware MediaCodec (e.g. 10-bit HEVC on 8-bit hardware decoders).
  Future<void> _applyAuto4kDecodeGuard() async {
    if (_applied4kSwTuning) return;
    _applied4kSwTuning = true;
    final p = _player;
    if (p == null || p.platform is! NativePlayer) return;
    final native = p.platform as NativePlayer;
    try {
      final curHw = (await native.getProperty('hwdec-current')).trim();
      if (curHw.isEmpty || curHw == 'no') {
        await Future.wait([
          native.setProperty('vd-lavc-fast', 'yes'),
          native.setProperty('vd-lavc-skiploopfilter', 'all'),
          native.setProperty('vd-lavc-framedrop', 'nonref'),
          native.setProperty('framedrop', 'decoder+vo'),
        ]);
      }
    } catch (_) {}
  }

  Future<void> _applyScaleHeight(int? height) async {
    final p = _player;
    if (p == null) return;

    if (_activeTranscodeHeight == null && _originalHeight == null) {
      final h = p.state.height ?? p.state.track.video.h;
      if (h != null && h > 0) {
        _originalHeight = h;
      }
    }

    if (p.platform is NativePlayer) {
      await _configureNativePlayerProperties(
        p.platform as NativePlayer,
        scaleHeight: height,
        forceHwCheck: true,
      );
    }
    if (mounted) {
      setState(() => _selectedScaleHeight = height);
    }
  }

  void _onVerticalDragStart(bool isLeft, DragStartDetails details) {
    _dragHideTimer?.cancel();
    setState(() {
      _activeDragType = isLeft ? 'brightness' : 'volume';
      _dragStartValue = isLeft ? _brightness : _volume;
      _dragStartY = details.globalPosition.dy;
    });
  }

  Future<void> _onVerticalDragUpdate(
    bool isLeft,
    DragUpdateDetails details,
    double viewHeight,
  ) async {
    final sensitivity = (viewHeight * 0.6).clamp(160.0, 500.0);
    final delta = (_dragStartY - details.globalPosition.dy) / sensitivity;
    if (isLeft) {
      final next = (_dragStartValue + delta).clamp(0.01, 1.0);
      setState(() {
        _activeDragType = 'brightness';
        _brightness = next;
      });
      try {
        await _controlsChannel.invokeMethod<void>('setBrightness', {
          'value': next,
        });
      } catch (_) {}
    } else {
      final next = (_dragStartValue + delta).clamp(0.0, 1.0);
      setState(() {
        _activeDragType = 'volume';
        _volume = next;
      });
      try {
        await _controlsChannel.invokeMethod<void>('setVolume', {'value': next});
      } catch (_) {
        await _player?.setVolume(next * 100.0);
      }
    }
  }

  void _onVerticalDragEnd() {
    _dragHideTimer?.cancel();
    _dragHideTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() => _activeDragType = null);
      }
    });
  }

  Future<void> _toggleCenterPlayPause() async {
    final p = _player;
    if (p == null || p.state.buffering) return;
    final willPlay = !p.state.playing;
    await p.playOrPause();
    if (!mounted) return;
    _centerIndicatorTimer?.cancel();
    setState(() {
      _centerIndicatorPlaying = willPlay;
      _showCenterPlayPauseIndicator = true;
    });
    _centerIndicatorTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _showCenterPlayPauseIndicator = false);
      }
    });
    if (willPlay && _showControls) {
      _scheduleHideControls();
    }
  }

  Future<void> _startLongPressSpeed() async {
    final p = _player;
    if (p == null || _isLongPressSpeed) return;
    if (!p.state.playing || p.state.buffering) return;
    _rateBeforeLongPress = p.state.rate;
    await p.setRate(2.0);
    if (mounted) {
      setState(() => _isLongPressSpeed = true);
    }
  }

  Future<void> _endLongPressSpeed() async {
    if (!_isLongPressSpeed) return;
    final p = _player;
    if (p != null) {
      await p.setRate(_rateBeforeLongPress);
    }
    if (mounted) {
      setState(() => _isLongPressSpeed = false);
    }
  }

  List<int> _availableQualityValues() {
    final orig = _originalHeight;
    final list = <int>[
      0,
      if (orig == null || orig > 720) 720,
      if (orig == null || orig > 480) 480,
      if (orig == null || orig > 360) 360,
    ];
    final selected = _selectedScaleHeight;
    if (selected != null && !list.contains(selected)) {
      list.add(selected);
    }
    return list;
  }

  Widget _buildQualityDropdownButton() {
    final activeHeight = _selectedScaleHeight;
    final origHeight = _originalHeight;
    final pillLabel = activeHeight != null
        ? '${activeHeight}p'
        : (origHeight != null && origHeight > 0 ? '${origHeight}p' : 'HD');
    final options = _availableQualityValues();

    String qualityTitle(int val) {
      if (val == 0) {
        return origHeight != null && origHeight > 0
            ? 'Original (${origHeight}p)'
            : 'Original';
      }
      return '${val}p';
    }

    String qualityHint(int val) {
      if (val == 0) return 'Original stream';
      return 'Display scale • Lighter cache';
    }

    return PopupMenuButton<int>(
      tooltip: 'Video Quality',
      color: const Color(0xFF141724),
      elevation: 8,
      offset: const Offset(0, 38),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      onOpened: () => _hideTimer?.cancel(),
      onCanceled: _scheduleHideControls,
      onSelected: (val) {
        _scheduleHideControls();
        unawaited(_applyScaleHeight(val == 0 ? null : val));
      },
      itemBuilder: (_) => [
        for (final val in options)
          PopupMenuItem<int>(
            value: val,
            height: 40,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: ((val == 0 && activeHeight == null) ||
                          val == activeHeight)
                      ? _kAccent
                      : Colors.transparent,
                ),
                const SizedBox(width: 8),
                Text(
                  qualityTitle(val),
                  style: TextStyle(
                    color: ((val == 0 && activeHeight == null) ||
                            val == activeHeight)
                        ? _kAccent
                        : Colors.white,
                    fontSize: 13.5,
                    fontWeight: ((val == 0 && activeHeight == null) ||
                            val == activeHeight)
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  qualityHint(val),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: (activeHeight != null ? _kAccent : Colors.white)
                .withValues(alpha: 0.28),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              pillLabel,
              style: TextStyle(
                color: activeHeight != null ? _kAccent : Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 17,
              color: activeHeight != null ? _kAccent : Colors.white70,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSpeedSheet() async {
    final p = _player;
    if (p == null) return;
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final currentRate = p.state.rate;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141724),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Text(
                'Playback Speed',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final speed in speeds)
              ListTile(
                title: Text(
                  '${speed}x',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                trailing: (currentRate - speed).abs() < 0.05
                    ? const Icon(Icons.check_rounded, color: _kAccent)
                    : null,
                onTap: () {
                  p.setRate(speed);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openExternally() async {
    final target = (widget.fallbackWebUrl?.isNotEmpty ?? false)
        ? widget.fallbackWebUrl!
        : widget.streamUrl;
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  bool get _hasThumbnailSource {
    final local = _resolvedThumbPath?.trim() ?? '';
    if (local.isNotEmpty && File(local).existsSync()) return true;
    final url = widget.thumbnailUrl?.trim() ?? '';
    return url.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    final duration = _effectiveDuration;
    final maxMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final clampedPosMs = _sliderValueMs.clamp(0.0, maxMs);
    final clampedBufMs = _bufferedPosition.inMilliseconds
        .toDouble()
        .clamp(clampedPosMs, maxMs);
    final buffering = p?.state.buffering ?? false;
    final showLoading = buffering || !_hasFirstFrame;
    final playing = p?.state.playing ?? false;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _exitPlayer();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_videoController != null)
              Center(
                child: Video(
                  controller: _videoController!,
                  controls: NoVideoControls,
                  fit: _videoFit,
                ),
              ),

            if (_hasThumbnailSource)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hasFirstFrame ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOut,
                  child: MkvStreamThumbnailBackdrop(
                    thumbnailPath: _resolvedThumbPath,
                    thumbnailUrl: widget.thumbnailUrl,
                  ),
                ),
              ),

            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                    onDoubleTap: () => _seekRelative(-10),
                    onLongPressStart: (_) => _startLongPressSpeed(),
                    onLongPressEnd: (_) => _endLongPressSpeed(),
                    onLongPressCancel: _endLongPressSpeed,
                    onVerticalDragStart: (d) => _onVerticalDragStart(true, d),
                    onVerticalDragUpdate: (d) => _onVerticalDragUpdate(
                      true,
                      d,
                      MediaQuery.sizeOf(context).height,
                    ),
                    onVerticalDragEnd: (_) => _onVerticalDragEnd(),
                    onVerticalDragCancel: _onVerticalDragEnd,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                    onDoubleTap: _toggleCenterPlayPause,
                    onLongPressStart: (_) => _startLongPressSpeed(),
                    onLongPressEnd: (_) => _endLongPressSpeed(),
                    onLongPressCancel: _endLongPressSpeed,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                    onDoubleTap: () => _seekRelative(10),
                    onLongPressStart: (_) => _startLongPressSpeed(),
                    onLongPressEnd: (_) => _endLongPressSpeed(),
                    onLongPressCancel: _endLongPressSpeed,
                    onVerticalDragStart: (d) => _onVerticalDragStart(false, d),
                    onVerticalDragUpdate: (d) => _onVerticalDragUpdate(
                      false,
                      d,
                      MediaQuery.sizeOf(context).height,
                    ),
                    onVerticalDragEnd: (_) => _onVerticalDragEnd(),
                    onVerticalDragCancel: _onVerticalDragEnd,
                  ),
                ),
              ],
            ),

            if (_activeDragType != null)
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 156,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.74),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _activeDragType == 'brightness'
                                  ? Icons.brightness_6_rounded
                                  : (_volume <= 0.01
                                        ? Icons.volume_off_rounded
                                        : Icons.volume_up_rounded),
                              color: _kAccent,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${((_activeDragType == 'brightness' ? _brightness : _volume) * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _activeDragType == 'brightness'
                                ? _brightness
                                : _volume,
                            minHeight: 5,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              _kAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (_isLongPressSpeed)
              Positioned(
                top: 22,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _kAccent.withValues(alpha: 0.5),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.fast_forward_rounded,
                            color: _kAccent,
                            size: 18,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '2x Speed',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            if (_showCenterPlayPauseIndicator)
              IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _showCenterPlayPauseIndicator ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 160),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Icon(
                        _centerIndicatorPlaying
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
                    ),
                  ),
                ),
              ),

            IgnorePointer(
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedOpacity(
                      opacity: _showRewindIndicator ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 160),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.fast_rewind_rounded,
                              color: Colors.white,
                              size: 42,
                            ),
                            SizedBox(height: 4),
                            Text(
                              '-10s',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: AnimatedOpacity(
                      opacity: _showForwardIndicator ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 160),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.fast_forward_rounded,
                              color: Colors.white,
                              size: 42,
                            ),
                            SizedBox(height: 4),
                            Text(
                              '+10s',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            if (_errorMessage == null && showLoading)
              IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        color: _kAccent,
                        strokeWidth: 3,
                      ),
                      const SizedBox(height: 10),
                      ValueListenableBuilder<StreamNetworkStats>(
                        valueListenable: _streamProxy.stats,
                        builder: (_, net, _) {
                          final isOffline =
                              net.phase == StreamConnectionPhase.offline;
                          final label = isOffline
                              ? 'Waiting for internet...'
                              : net.formattedSpeed();
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: (isOffline ? Colors.orangeAccent : _kAccent)
                                    .withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                color: isOffline
                                    ? Colors.orangeAccent
                                    : Colors.white70,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

            // Visual-only HUD gradient (never blocks gestures)
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.25, 0.72, 1.0],
                      colors: [
                        Colors.black.withValues(alpha: 0.78),
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.84),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Top Bar (only occupies top strip so left/right gestures always work)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: Colors.white,
                            ),
                            onPressed: _exitPlayer,
                          ),
                          Expanded(
                            child: Text(
                              _cleanTitle(widget.title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          _buildQualityDropdownButton(),
                          IconButton(
                            tooltip: 'Audio Track',
                            icon: const Icon(
                              Icons.audiotrack_rounded,
                              color: Colors.white,
                              size: 21,
                            ),
                            onPressed: _showAudioTracksSheet,
                          ),
                          IconButton(
                            tooltip: 'Subtitles',
                            icon: const Icon(
                              Icons.subtitles_rounded,
                              color: Colors.white,
                              size: 21,
                            ),
                            onPressed: _showSubtitleTracksSheet,
                          ),
                          IconButton(
                            tooltip: 'Playback Speed',
                            icon: const Icon(
                              Icons.speed_rounded,
                              color: Colors.white,
                              size: 21,
                            ),
                            onPressed: _showSpeedSheet,
                          ),
                          IconButton(
                            tooltip: 'Aspect Fit',
                            icon: Icon(
                              _videoFit == BoxFit.contain
                                  ? Icons.fit_screen_rounded
                                  : Icons.crop_free_rounded,
                              color: Colors.white,
                              size: 21,
                            ),
                            onPressed: () {
                              setState(() {
                                _videoFit = _videoFit == BoxFit.contain
                                    ? BoxFit.cover
                                    : BoxFit.contain;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Center Play/Pause/Skip (compact min-size so left/right halves stay interactive)
            if (_errorMessage == null && !showLoading && p != null)
              Center(
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          iconSize: 34,
                          color: Colors.white70,
                          icon: const Icon(Icons.replay_10_rounded),
                          onPressed: () => _seekRelative(-10),
                        ),
                        const SizedBox(width: 24),
                        Material(
                          color: Colors.black54,
                          shape: const CircleBorder(),
                          child: IconButton(
                            iconSize: 48,
                            color: Colors.white,
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            onPressed: () {
                              p.playOrPause();
                              _scheduleHideControls();
                            },
                          ),
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          iconSize: 34,
                          color: Colors.white70,
                          icon: const Icon(Icons.forward_10_rounded),
                          onPressed: () => _seekRelative(10),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Bottom Timeline Bar
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Row(
                        children: [
                          Text(
                            _formatDuration(
                              Duration(milliseconds: clampedPosMs.round()),
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.5,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6.5,
                                ),
                                activeTrackColor: _kAccent,
                                secondaryActiveTrackColor: Colors.white54,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: _kAccent,
                                overlayColor: _kAccent.withValues(alpha: 0.2),
                              ),
                              child: Slider(
                                value: clampedPosMs,
                                secondaryTrackValue: clampedBufMs,
                                min: 0,
                                max: maxMs,
                                onChangeStart: (_) {
                                  _hideTimer?.cancel();
                                  setState(() => _isSeekingSlider = true);
                                },
                                onChanged: (v) {
                                  setState(() => _sliderValueMs = v);
                                },
                                onChangeEnd: (v) async {
                                  await _seekToEffective(
                                    Duration(milliseconds: v.round()),
                                  );
                                  if (mounted) {
                                    setState(() => _isSeekingSlider = false);
                                    _scheduleHideControls();
                                  }
                                },
                              ),
                            ),
                          ),
                          Text(
                            _formatDuration(duration),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Render error card ABOVE the HUD controls so buttons are always clickable
            if (_errorMessage != null)
              Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141724).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const SizedBox(width: 28),
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Colors.redAccent,
                            size: 34,
                          ),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white54,
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _errorMessage = null),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _kAccent,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: _initAndOpen,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Retry'),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white24),
                            ),
                            onPressed: _openExternally,
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 17,
                            ),
                            label: const Text('Open Link'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Renders the best available video thumbnail (local captured frame first, then
/// cached network artwork) behind the player loader before the first frame renders.
class MkvStreamThumbnailBackdrop extends StatelessWidget {
  final String? thumbnailPath;
  final String? thumbnailUrl;

  const MkvStreamThumbnailBackdrop({
    super.key,
    this.thumbnailPath,
    this.thumbnailUrl,
  });

  Widget _buildNetworkThumbnail() {
    final url = thumbnailUrl?.trim() ?? '';
    if (url.isEmpty) return const SizedBox.shrink();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, _) => const SizedBox.shrink(),
      errorWidget: (_, _, _) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final local = thumbnailPath?.trim() ?? '';
    final Widget imageLayer = (local.isNotEmpty && File(local).existsSync())
        ? Image.file(
            File(local),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildNetworkThumbnail(),
          )
        : _buildNetworkThumbnail();

    return Stack(
      fit: StackFit.expand,
      children: [
        imageLayer,
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.1,
              colors: [
                Colors.black.withValues(alpha: 0.34),
                Colors.black.withValues(alpha: 0.68),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
