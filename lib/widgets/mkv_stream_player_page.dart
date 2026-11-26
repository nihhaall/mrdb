import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
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

  const MkvStreamPlayerPage({
    super.key,
    required this.title,
    required this.streamUrl,
    this.fallbackWebUrl,
    this.formatLabel,
    this.progressKey,
    this.initialPosition,
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
  bool _isLongPressSpeed = false;
  double _rateBeforeLongPress = 1.0;
  BoxFit _videoFit = BoxFit.contain;
  int? _selectedScaleHeight;
  String? _errorMessage;

  static const MethodChannel _controlsChannel = MethodChannel(
    'com.mrdb.flit/player_controls',
  );
  double _brightness = 0.5;
  double _volume = 1.0;
  String? _activeDragType; // 'brightness' or 'volume'
  double _dragStartValue = 0.5;
  double _dragStartY = 0;
  bool _didInitialFrameCapture = false;
  bool _hasSurfaceFrame = false;
  bool _hasFirstFrame = false;
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  static final RegExp _trailingExtRegex = RegExp(
    r'\.(mkv|mp4|avi|mov|webm|m4v|ts|flv)$',
    caseSensitive: false,
  );

  String _cleanTitle(String raw) => raw.replaceFirst(_trailingExtRegex, '').trim();

  Timer? _hideTimer;
  Timer? _indicatorTimer;
  Timer? _dragHideTimer;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadDeviceLevels();
    _initAndOpen();
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
    });
    try {
      MediaKit.ensureInitialized();
      if (_player == null) {
        final p = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 16 * 1024 * 1024,
          ),
        );
        final vc = VideoController(p);
        _player = p;
        _videoController = vc;
        vc.waitUntilFirstFrameRendered.then((_) {
          if (!mounted) return;
          _hasSurfaceFrame = true;
          final hasResume = widget.initialPosition != null &&
              widget.initialPosition! > Duration.zero;
          if (!hasResume || p.state.position > Duration.zero) {
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
            }
          }),
        );
        _subs.add(
          p.stream.position.listen((pos) {
            if (!mounted || _isSeekingSlider) return;
            final shouldRevealFirstFrame =
                !_hasFirstFrame && _hasSurfaceFrame && pos > Duration.zero;
            setState(() {
              _sliderValueMs = pos.inMilliseconds.toDouble();
              if (pos > Duration.zero && _errorMessage != null) {
                _errorMessage = null;
              }
              if (shouldRevealFirstFrame) {
                _hasFirstFrame = true;
              }
            });
            final now = DateTime.now();
            if (pos >= const Duration(minutes: 10) &&
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
          p.stream.buffering.listen((_) {
            if (mounted) setState(() {});
          }),
        );
        _subs.add(
          p.stream.duration.listen((_) {
            if (mounted) setState(() {});
          }),
        );
        _subs.add(
          p.stream.tracks.listen((_) {
            if (mounted) setState(() {});
          }),
        );
      } else {
        _videoController?.waitUntilFirstFrameRendered.then((_) {
          if (!mounted) return;
          _hasSurfaceFrame = true;
          final p = _player;
          final hasResume = widget.initialPosition != null &&
              widget.initialPosition! > Duration.zero;
          if (!hasResume || (p != null && p.state.position > Duration.zero)) {
            setState(() => _hasFirstFrame = true);
          }
        });
      }

      if (_player!.platform is NativePlayer) {
        final native = _player!.platform as NativePlayer;
        await Future.wait([
          native.setProperty('cache', 'yes'),
          native.setProperty('demuxer-max-bytes', '64MiB'),
          native.setProperty('demuxer-readahead-secs', '30'),
          native.setProperty('demuxer-lavf-probesize', '500000'),
          native.setProperty('demuxer-lavf-analyzeduration', '1.0'),
          native.setProperty('cache-pause', 'yes'),
          native.setProperty('cache-pause-initial', 'yes'),
          native.setProperty('cache-pause-wait', '1'),
          native.setProperty('hr-seek', 'no'),
          native.setProperty(
            'stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
          ),
        ]);
      }

      final hasInitialPos = widget.initialPosition != null &&
          widget.initialPosition! > Duration.zero;

      if (mounted) setState(() {});
      await _player!.open(
        Media(
          widget.streamUrl,
          start: hasInitialPos ? widget.initialPosition : null,
        ),
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

  Future<void> _captureFrameNow() async {
    final p = _player;
    if (p == null) return;
    try {
      final bytes = await p.screenshot(format: 'image/jpeg');
      if (bytes != null && bytes.isNotEmpty) {
        final key = (widget.progressKey?.trim().isNotEmpty ?? false)
            ? widget.progressKey!.trim()
            : widget.streamUrl.trim();
        await TelegramStreamService.instance.saveCapturedFrame(key, bytes);
      }
    } catch (_) {}
  }

  Future<void> _saveProgressNow() async {
    final p = _player;
    if (p == null) return;
    final key = (widget.progressKey?.trim().isNotEmpty ?? false)
        ? widget.progressKey!.trim()
        : widget.streamUrl.trim();
    await TelegramStreamService.instance.saveWatchProgress(
      key,
      p.state.position,
      p.state.duration,
    );
  }

  @override
  void dispose() {
    final p = _player;
    if (p != null && p.state.position >= const Duration(minutes: 10)) {
      _captureFrameNow();
    }
    _saveProgressNow();
    _hideTimer?.cancel();
    _indicatorTimer?.cancel();
    _dragHideTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
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
    final p = _player;
    if (p != null && p.state.position >= const Duration(minutes: 20)) {
      await _captureFrameNow();
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

  void _seekRelative(int seconds) {
    final p = _player;
    if (p == null) return;
    final current = p.state.position;
    final total = p.state.duration;
    var next = current + Duration(seconds: seconds);
    if (next < Duration.zero) next = Duration.zero;
    if (total > Duration.zero && next > total) next = total;
    p.seek(next);

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
    final tracks = p.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
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
                p.setAudioTrack(AudioTrack.auto());
                Navigator.pop(ctx);
              },
            ),
            for (var i = 0; i < tracks.length; i++)
              ListTile(
                leading: Icon(
                  Icons.audiotrack_rounded,
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
                  p.setAudioTrack(tracks[i]);
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

  Future<void> _applyScaleHeight(int? height) async {
    final p = _player;
    if (p == null) return;
    if (p.platform is NativePlayer) {
      final native = p.platform as NativePlayer;
      if (height == null) {
        await native.setProperty('vf', '');
        await native.setProperty('hwdec', 'auto-safe');
      } else {
        // Android MediaCodec zero-copy bypasses libmpv vf filters unless
        // hwdec uses mediacodec-copy.
        await native.setProperty('hwdec', 'mediacodec-copy');
        await native.setProperty('vf', 'scale=-2:$height:flags=fast_bilinear');
      }
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

  Future<void> _startLongPressSpeed() async {
    final p = _player;
    if (p == null || _isLongPressSpeed) return;
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

  Future<void> _showQualitySheet() async {
    final p = _player;
    if (p == null) return;
    final videoTracks = p.state.tracks.video
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final currentTrack = p.state.track.video;
    final currentHeight = p.state.height ?? currentTrack.h;
    final hasMultiTracks = videoTracks.length > 1;
    final scaleOptions = <int?>[
      null,
      if (currentHeight == null || currentHeight > 720) 720,
      if (currentHeight == null || currentHeight > 480) 480,
      if (currentHeight == null || currentHeight > 360) 360,
    ];

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
                'Video Quality',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (hasMultiTracks) ...[
              ListTile(
                leading: Icon(
                  Icons.auto_awesome_rounded,
                  color: currentTrack.id == 'auto' ? _kAccent : Colors.white54,
                ),
                title: const Text(
                  'Auto',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                trailing: currentTrack.id == 'auto'
                    ? const Icon(Icons.check_rounded, color: _kAccent)
                    : null,
                onTap: () async {
                  await p.setVideoTrack(VideoTrack.auto());
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              for (var i = 0; i < videoTracks.length; i++)
                ListTile(
                  leading: Icon(
                    Icons.high_quality_rounded,
                    color: currentTrack.id == videoTracks[i].id
                        ? _kAccent
                        : Colors.white54,
                  ),
                  title: Text(
                    videoTracks[i].h != null
                        ? '${videoTracks[i].h}p${videoTracks[i].codec != null ? ' • ${videoTracks[i].codec!.toUpperCase()}' : ''}'
                        : _trackLabel(videoTracks[i], i + 1),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  trailing: currentTrack.id == videoTracks[i].id
                      ? const Icon(Icons.check_rounded, color: _kAccent)
                      : null,
                  onTap: () async {
                    await p.setVideoTrack(videoTracks[i]);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              const Divider(color: Color(0xFF202534), height: 16),
            ],
            for (final h in scaleOptions)
              ListTile(
                leading: Icon(
                  h == null ? Icons.hd_rounded : Icons.tune_rounded,
                  color: _selectedScaleHeight == h ? _kAccent : Colors.white54,
                ),
                title: Text(
                  h == null
                      ? 'Original${currentHeight != null && currentHeight > 0 ? ' (${currentHeight}p)' : ''}'
                      : '${h}p',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                trailing: _selectedScaleHeight == h
                    ? const Icon(Icons.check_rounded, color: _kAccent)
                    : null,
                onTap: () async {
                  await _applyScaleHeight(h);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
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

  @override
  Widget build(BuildContext context) {
    final p = _player;
    final duration = p?.state.duration ?? Duration.zero;
    final maxMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final clampedPosMs = _sliderValueMs.clamp(0.0, maxMs);
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
              const IgnorePointer(
                child: Center(
                  child: CircularProgressIndicator(
                    color: _kAccent,
                    strokeWidth: 3,
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
                          IconButton(
                            tooltip: 'Quality',
                            icon: const Icon(
                              Icons.high_quality_rounded,
                              color: Colors.white,
                              size: 21,
                            ),
                            onPressed: _showQualitySheet,
                          ),
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
                                inactiveTrackColor: Colors.white24,
                                thumbColor: _kAccent,
                                overlayColor: _kAccent.withValues(alpha: 0.2),
                              ),
                              child: Slider(
                                value: clampedPosMs,
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
                                  await p?.seek(
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
