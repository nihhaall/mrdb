import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/main.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/services/video_frame_thumbnail_service.dart';
import 'package:mrdb/widgets/mkv_stream_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

class TelegramVideosPage extends StatefulWidget {
  const TelegramVideosPage({super.key});

  @override
  State<TelegramVideosPage> createState() => _TelegramVideosPageState();
}

class _TelegramVideosPageState extends State<TelegramVideosPage> {
  static const Color _kBgColor = Color(0xFF000000);
  static const Color _kCardBg = Color(0xFF0E0E12);
  static const Color _kSurfaceLight = Color(0xFF14141A);
  static const Color _kInputBg = Color(0xFF101015);
  static const Color _kCardBorder = Color(0xFF1F1F28);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFFFFFFF);
  static const Color _kTextSecondary = Color(0xFF9E9EA8);

  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;

  bool _loadingFeed = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextOffset = 0;
  bool _resolvingCode = false;
  bool _searching = false;
  bool _isOwner = false;
  String? _feedError;

  List<TelegramVideoItem> _botVideos = [];
  List<TelegramVideoItem> _matchingVideos = [];
  List<Map<String, dynamic>> _matchingMovies = [];
  List<TelegramVideoItem> _savedLinks = [];
  Map<String, VideoWatchProgress> _progressMap = {};
  Map<String, String> _capturedFrames = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    VideoFrameThumbnailService.instance.addListener(_onFrameExtracted);
    _loadInitial();
  }

  @override
  void dispose() {
    VideoFrameThumbnailService.instance.removeListener(_onFrameExtracted);
    _searchDebounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _codeController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onFrameExtracted() {
    if (!mounted) return;
    final extracted = VideoFrameThumbnailService.instance.cachedPaths;
    if (extracted.isNotEmpty) {
      _capturedFrames.addAll(extracted);
    }
    setState(() {});
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 250) {
      _loadMoreVideos();
    }
  }

  Future<void> _loadInitial() async {
    VideoFrameThumbnailService.instance.clearFailedCache();
    setState(() {
      _loadingFeed = true;
      _feedError = null;
      _hasMore = true;
      _nextOffset = 0;
    });
    final results = await Future.wait([
      TelegramStreamService.instance.fetchBotVideos(limit: 20, offset: 0),
      TelegramStreamService.instance.getSavedManualVideos(),
      TelegramStreamService.instance.getAllWatchProgress(),
      TelegramStreamService.instance.getAllCapturedFrames(),
      SharedPreferences.getInstance(),
    ]);
    final feed = results[0] as TelegramVideosResult;
    final saved = results[1] as List<TelegramVideoItem>;
    final progress = results[2] as Map<String, VideoWatchProgress>;
    final captured = results[3] as Map<String, String>;
    final prefs = results[4] as SharedPreferences;
    final dedupedFeed = TelegramStreamService.dedupeVideos(feed.videos);
    final feedCodes = dedupedFeed
        .map((v) => v.streamCode.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toSet();
    final feedUrls = dedupedFeed.map((v) => v.streamUrl.trim()).toSet();
    final feedTitles = dedupedFeed
        .map((v) => v.title.trim().toLowerCase())
        .where((t) => t.isNotEmpty)
        .toSet();
    final uniqueSaved = TelegramStreamService.dedupeVideos(saved).where((v) {
      final code = v.streamCode.trim().toUpperCase();
      if (code.isNotEmpty && feedCodes.contains(code)) return false;
      if (feedUrls.contains(v.streamUrl.trim())) return false;
      final t = v.title.trim().toLowerCase();
      if (t.isNotEmpty && feedTitles.contains(t)) return false;
      return true;
    }).toList();
    if (!mounted) return;
    setState(() {
      _botVideos = dedupedFeed;
      _feedError = feed.errorMessage;
      _hasMore = feed.hasMore;
      _nextOffset = feed.rawCount > 0 ? feed.rawCount : dedupedFeed.length;
      _savedLinks = uniqueSaved;
      _progressMap = progress;
      _capturedFrames = captured;
      _isOwner = prefs.getBool('is_owner') ?? false;
      _loadingFeed = false;
    });
  }

  Future<void> _refreshProgress() async {
    final results = await Future.wait([
      TelegramStreamService.instance.getAllWatchProgress(),
      TelegramStreamService.instance.getAllCapturedFrames(),
    ]);
    if (!mounted) return;
    setState(() {
      _progressMap = results[0] as Map<String, VideoWatchProgress>;
      _capturedFrames = results[1] as Map<String, String>;
    });
  }

  Future<void> _loadMoreVideos() async {
    if (_loadingFeed ||
        _loadingMore ||
        !_hasMore ||
        _searchController.text.trim().isNotEmpty) {
      return;
    }
    setState(() => _loadingMore = true);
    final res = await TelegramStreamService.instance.fetchBotVideos(
      limit: 20,
      offset: _nextOffset,
    );
    if (!mounted) return;
    final merged = TelegramStreamService.dedupeVideos([
      ..._botVideos,
      ...res.videos,
    ]);
    setState(() {
      _botVideos = merged;
      _nextOffset += res.rawCount > 0 ? res.rawCount : res.videos.length;
      _hasMore = res.hasMore && res.rawCount > 0;
      _loadingMore = false;
    });
  }

  Future<void> _playByCode() async {
    final input = _codeController.text.trim();
    if (input.isEmpty) {
      showScaffoldMsg(context, txt: 'Enter a stream code from the bot');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _resolvingCode = true);

    final lookup = await TelegramStreamService.instance.resolveStreamCode(
      input,
    );
    if (!mounted) return;
    setState(() => _resolvingCode = false);

    if (lookup.video == null) {
      showScaffoldMsg(
        context,
        txt: lookup.errorMessage ?? 'Could not resolve stream code',
      );
      return;
    }

    await TelegramStreamService.instance.saveManualVideo(lookup.video!);
    _codeController.clear();
    await _loadInitial();
    if (mounted) {
      _openVideo(lookup.video!);
    }
  }

  Future<void> _showStreamCodeDialog() async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Enter Stream Code',
      barrierColor: Colors.black.withValues(alpha: 0.78),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (_, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: 0.93,
            end: 1.0,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
      pageBuilder: (ctx, _, _) => StatefulBuilder(
        builder: (dCtx, setDialogState) => Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: MediaQuery.sizeOf(ctx).width * 0.9,
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _kCardBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: _kAccent.withValues(alpha: 0.32),
                  width: 1.2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _kAccent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(
                            color: _kAccent.withValues(alpha: 0.35),
                          ),
                        ),
                        child: const Icon(
                          Icons.vpn_key_rounded,
                          color: _kAccent,
                          size: 17,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Stream with Code',
                          style: TextStyle(
                            color: _kTextPrimary,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _kTextSecondary,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Send any movies to @FileToSpeedLink_Bot to get a stream code.',
                    style: TextStyle(color: _kTextSecondary, fontSize: 12.5),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: _kInputBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _kCardBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            autofocus: true,
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                            textCapitalization: TextCapitalization.characters,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) async {
                              Navigator.pop(ctx);
                              await _playByCode();
                            },
                            decoration: const InputDecoration(
                              hintText: 'MRDB-...',
                              hintStyle: TextStyle(color: _kTextSecondary),
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Paste',
                          icon: const Icon(
                            Icons.content_paste_rounded,
                            color: _kAccent,
                            size: 18,
                          ),
                          onPressed: _pasteFromClipboard,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _kTextPrimary,
                            backgroundColor: _kSurfaceLight.withValues(
                              alpha: 0.45,
                            ),
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            side: const BorderSide(color: _kCardBorder),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _openBotInTelegram,
                          icon: const Icon(Icons.send_rounded, size: 15),
                          label: const Text(
                            'Open Bot',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kAccent,
                            foregroundColor: const Color(0xFF061310),
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _playByCode();
                          },
                          icon: const Icon(Icons.play_arrow_rounded, size: 19),
                          label: const Text(
                            'Stream Now',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) showScaffoldMsg(context, txt: 'Clipboard is empty');
      return;
    }
    _codeController.text = text;
  }

  void _onSearchChanged(String raw) {
    _searchDebounce?.cancel();
    final q = raw.trim();
    if (q.isEmpty) {
      setState(() {
        _searching = false;
        _matchingVideos = [];
        _matchingMovies = [];
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 350), () async {
      final results = await Future.wait([
        TelegramStreamService.instance.fetchBotVideos(query: q, limit: 30),
        TelegramStreamService.instance.searchTmdbMovies(q),
      ]);
      final videoRes = results[0] as TelegramVideosResult;
      final movies = results[1] as List<Map<String, dynamic>>;
      if (!mounted) return;
      setState(() {
        _matchingVideos = videoRes.videos;
        _matchingMovies = movies;
        _searching = false;
      });
    });
  }

  String _formatClock(int ms) {
    final totalSec = (ms / 1000).floor().clamp(0, 864000);
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  void _scheduleFrameExtraction(TelegramVideoItem item) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      VideoFrameThumbnailService.instance.requestFrame(item);
    });
  }

  Widget _buildThumbnailWidget(
    TelegramVideoItem item, {
    BoxFit fit = BoxFit.cover,
    Widget? fallback,
  }) {
    final key = TelegramStreamService.progressKeyFor(item);
    final localPath =
        _capturedFrames[key] ?? VideoFrameThumbnailService.instance.pathFor(key);
    if (localPath != null &&
        localPath.isNotEmpty &&
        File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        fit: fit,
        errorBuilder: (_, _, _) => _buildNetworkOrFallbackThumb(
          item,
          key: key,
          fit: fit,
          fallback: fallback,
        ),
      );
    }
    return _buildNetworkOrFallbackThumb(
      item,
      key: key,
      fit: fit,
      fallback: fallback,
    );
  }

  Widget _buildNetworkOrFallbackThumb(
    TelegramVideoItem item, {
    required String key,
    BoxFit fit = BoxFit.cover,
    Widget? fallback,
  }) {
    final isExtracting = VideoFrameThumbnailService.instance.isExtracting(key);
    final effectiveFallback = isExtracting
        ? Shimmer.fromColors(
            baseColor: _kSurfaceLight,
            highlightColor: const Color(0xFF232532),
            child: Container(color: _kSurfaceLight),
          )
        : (fallback ?? Container(color: _kSurfaceLight));

    if (item.thumbUrl != null && item.thumbUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: item.thumbUrl!,
        fit: fit,
        placeholder: (_, _) => effectiveFallback,
        errorWidget: (_, _, _) {
          _scheduleFrameExtraction(item);
          return effectiveFallback;
        },
      );
    }

    if (!isExtracting &&
        VideoFrameThumbnailService.instance.pathFor(key) == null) {
      _scheduleFrameExtraction(item);
    }
    return effectiveFallback;
  }

  Future<void> _openVideo(
    TelegramVideoItem item, {
    bool directResume = false,
  }) async {
    HapticFeedback.lightImpact();
    await TelegramStreamService.instance.saveManualVideo(item);
    final key = TelegramStreamService.progressKeyFor(item);
    final progress = _progressMap[key];
    Duration? startAt;

    if (progress != null && progress.canResume) {
      if (directResume) {
        startAt = Duration(milliseconds: progress.positionMs);
      } else {
        if (!mounted) return;
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _kCardBg,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: _kAccent.withValues(alpha: 0.32)),
            ),
            title: const Text(
              'Resume Movie?',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            content: Text(
              'You stopped at ${_formatClock(progress.positionMs)}.',
              style: const TextStyle(color: _kTextSecondary, fontSize: 13.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'start_over'),
                child: const Text(
                  'Start Over',
                  style: TextStyle(
                    color: _kTextSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: const Color(0xFF051410),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, 'resume'),
                child: const Text(
                  'Resume',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        );
        if (choice == null || !mounted) return;
        if (choice == 'resume') {
          startAt = Duration(milliseconds: progress.positionMs);
        } else {
          await TelegramStreamService.instance.clearWatchProgress(key);
          await _refreshProgress();
        }
      }
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MkvStreamPlayerPage(
          title: item.title,
          streamUrl: item.streamUrl,
          fallbackWebUrl: item.watchUrl,
          formatLabel: item.formatBadge,
          progressKey: key,
          initialPosition: startAt,
        ),
      ),
    );
    await _refreshProgress();
    final updatedSaved =
        await TelegramStreamService.instance.getSavedManualVideos();
    if (mounted) {
      setState(() {
        _savedLinks = updatedSaved;
      });
    }
  }

  Future<void> _openBotInTelegram() async {
    final uri = Uri.parse('https://t.me/FileToSpeedLink_Bot');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static final RegExp _extRegex = RegExp(
    r'\.(mkv|mp4|avi|mov|webm|m4v|ts|flv)$',
    caseSensitive: false,
  );

  String _friendlyTitle(TelegramVideoItem item) {
    final raw = (item.title.trim().isNotEmpty ? item.title : item.fileName)
        .replaceFirst(_extRegex, '')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return raw.isEmpty ? 'Movie Video' : raw;
  }

  Future<void> _confirmDeleteBotVideo(TelegramVideoItem item) async {
    final title = _friendlyTitle(item);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: _kCardBorder),
        ),
        title: const Text(
          'Delete Movie?',
          style: TextStyle(
            color: _kTextPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          'Remove "$title" from the Stream list?',
          style: const TextStyle(color: _kTextSecondary, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: _kTextSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE5534B),
              foregroundColor: Colors.white,
              elevation: 0,
              shadowColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await TelegramStreamService.instance.deleteBotVideo(item);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _botVideos.removeWhere(
          (v) =>
              (item.msgId != null && v.msgId == item.msgId) ||
              (item.streamCode.isNotEmpty && v.streamCode == item.streamCode),
        );
        _matchingVideos.removeWhere(
          (v) =>
              (item.msgId != null && v.msgId == item.msgId) ||
              (item.streamCode.isNotEmpty && v.streamCode == item.streamCode),
        );
        _savedLinks.removeWhere((v) => v.streamUrl == item.streamUrl);
      });
      showScaffoldMsg(context, txt: 'Movie removed');
    } else {
      showScaffoldMsg(context, txt: 'Could not delete movie from server');
    }
  }

  String _extractQualityLabel(TelegramVideoItem item) {
    final source = '${item.title} ${item.fileName}';
    final match = RegExp(
      r'\b(2160p|4K|1080p|720p|480p|360p)\b',
      caseSensitive: false,
    ).firstMatch(source);
    return match?.group(0)!.toUpperCase() ?? 'HD';
  }

  String _buildCardSubtitle(
    TelegramVideoItem item,
    VideoWatchProgress? progress,
  ) {
    final source = '${item.title} ${item.fileName}';
    final yearMatch = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(source);

    final parts = <String>[
      if (yearMatch != null) yearMatch.group(0)!,
      if (item.fileSize > 0) TelegramStreamService.formatBytes(item.fileSize),
    ];
    if (progress != null && progress.positionMs >= 3000) {
      parts.add('${_formatClock(progress.positionMs)} watched');
    }
    if (parts.isEmpty) return 'Tap to stream';
    return parts.join('  •  ');
  }

  Future<void> _copyStreamCode(TelegramVideoItem item) async {
    final code = item.streamCode.trim();
    if (code.isEmpty) return;
    HapticFeedback.mediumImpact();
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      showScaffoldMsg(context, txt: 'Stream code copied: $code');
    }
  }

  Widget _buildMovieGridCard(TelegramVideoItem item, {bool canDelete = false}) {
    final title = _friendlyTitle(item);
    final quality = _extractQualityLabel(item);
    final progress = _progressMap[TelegramStreamService.progressKeyFor(item)];
    final hasProgress = progress != null && progress.positionMs >= 3000;
    final sub = _buildCardSubtitle(item, progress);

    return Container(
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasProgress ? _kAccent.withValues(alpha: 0.45) : _kCardBorder,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          onTap: () => _openVideo(item),
          onLongPress: () => _copyStreamCode(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: Container(
                  color: _kSurfaceLight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildThumbnailWidget(
                        item,
                        fallback: Container(
                          color: _kSurfaceLight,
                          child: const Center(
                            child: Icon(
                              Icons.movie_creation_outlined,
                              color: _kTextSecondary,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                      Container(
                        color: Colors.black.withValues(alpha: 0.2),
                      ),
                      Center(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _kAccent.withValues(alpha: 0.8),
                              width: 1.2,
                            ),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: _kAccent,
                            size: 24,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 7,
                        left: 7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: _kAccent.withValues(alpha: 0.35),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            quality,
                            style: const TextStyle(
                              color: _kAccent,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ),
                      if (canDelete)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: GestureDetector(
                            onTap: () => _confirmDeleteBotVideo(item),
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.75),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.delete_outline_rounded,
                                color: Color(0xFFFF7B72),
                                size: 15,
                              ),
                            ),
                          ),
                        ),
                      if (hasProgress && progress.fraction > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress.fraction,
                            minHeight: 3,
                            backgroundColor: Colors.black45,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              _kAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: Container(
                  color: _kCardBg,
                  padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          height: 1.22,
                        ),
                      ),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasProgress ? _kAccent : _kTextSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMovieCard(Map<String, dynamic> m) {
    final poster = m['poster_path']?.toString().trim() ?? '';
    final hasPoster = poster.isNotEmpty && poster != 'null';
    final title = (m['title'] ?? m['name'] ?? 'Movie').toString();
    final year = (m['release_date'] ?? '').toString().split('-').first;
    final rating = (m['vote_average'] as num?)?.toDouble() ?? 0.0;
    final id = m['id'];

    Widget fallbackPoster() => Container(
      width: 106,
      height: 150,
      decoration: BoxDecoration(
        color: _kSurfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.movie_outlined, color: _kTextSecondary, size: 28),
          SizedBox(height: 4),
          Text(
            'No Poster',
            style: TextStyle(color: _kTextSecondary, fontSize: 10),
          ),
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (id == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MoviePreview(
              movieId: id,
              initialMovie: m,
              posterPath: poster,
              title: title,
              heroTag: 'stream_movie_$id',
            ),
          ),
        );
      },
      child: SizedBox(
        width: 106,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'stream_movie_$id',
              child: Container(
                width: 106,
                height: 150,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kCardBorder),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasPoster)
                        CachedNetworkImage(
                          imageUrl: '${AppConstants.baseImageUrl}$poster',
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => fallbackPoster(),
                        )
                      else
                        fallbackPoster(),
                      if (rating > 0)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  color: Color(0xFFFFB703),
                                  size: 11,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  rating.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (year.isNotEmpty)
              Text(
                year,
                style: const TextStyle(color: _kTextSecondary, fontSize: 10.5),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerGrid({int count = 4}) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF101015),
      highlightColor: const Color(0xFF1C1C24),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.84,
        ),
        itemBuilder: (_, _) => Container(
          decoration: BoxDecoration(
            color: _kCardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _kCardBorder),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    color: _kSurfaceLight,
                    child: Stack(
                      children: [
                        Center(
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: const BoxDecoration(
                              color: Color(0xFF181820),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 7,
                          left: 7,
                          child: Container(
                            width: 38,
                            height: 16,
                            decoration: BoxDecoration(
                              color: const Color(0xFF181820),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Container(
                    color: _kCardBg,
                    padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              height: 12,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: _kSurfaceLight,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Container(
                              height: 12,
                              width: 80,
                              decoration: BoxDecoration(
                                color: _kSurfaceLight,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ],
                        ),
                        Container(
                          height: 10,
                          width: 65,
                          decoration: BoxDecoration(
                            color: _kSurfaceLight,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kCardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: _kAccent.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            child: const Icon(
              Icons.movie_filter_rounded,
              color: _kAccent,
              size: 30,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No Movies in Stream Library',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Stream movies directly with fast seek and resume.\nSend video files to your Telegram bot or paste a stream code.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kTextSecondary,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: const Color(0xFF051410),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _showStreamCodeDialog,
                icon: const Icon(Icons.vpn_key_rounded, size: 16),
                label: const Text(
                  'Enter Stream Code',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kTextPrimary,
                  backgroundColor: _kSurfaceLight.withValues(alpha: 0.45),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  side: const BorderSide(color: _kCardBorder),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _openBotInTelegram,
                icon: const Icon(Icons.send_rounded, size: 15),
                label: const Text(
                  'Open Telegram Bot',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded, color: _kTextSecondary),
                onPressed: _loadInitial,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.orangeAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            color: Colors.orangeAccent,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _feedError ?? 'Error loading feed',
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 12.5,
              ),
            ),
          ),
          TextButton(
            onPressed: _loadInitial,
            child: const Text(
              'Retry',
              style: TextStyle(
                color: _kAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContinueWatchStrip() {
    final continueItems = <({TelegramVideoItem item, int timestamp})>[];
    for (final item in _savedLinks) {
      final p = _progressMap[TelegramStreamService.progressKeyFor(item)];
      final ts = p?.updatedAtMs ?? item.createdAt?.millisecondsSinceEpoch ?? 0;
      continueItems.add((item: item, timestamp: ts));
    }

    for (final item in _botVideos) {
      if (_savedLinks.any((s) => s.streamUrl == item.streamUrl)) continue;
      final p = _progressMap[TelegramStreamService.progressKeyFor(item)];
      if (p != null && p.positionMs >= 3000) {
        continueItems.add((item: item, timestamp: p.updatedAtMs));
      }
    }

    if (continueItems.isEmpty) return const SizedBox.shrink();
    continueItems.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final list = continueItems.map((e) => e.item).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Continue Watch', count: list.length),
        const SizedBox(height: 10),
        SizedBox(
          height: 80,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, idx) {
              final item = list[idx];
              final title = _friendlyTitle(item);
              final progress =
                  _progressMap[TelegramStreamService.progressKeyFor(item)];
              final isSaved =
                  _savedLinks.any((s) => s.streamUrl == item.streamUrl);
              final hasProgress =
                  progress != null && progress.positionMs >= 3000;
              final sub = hasProgress
                  ? '${_formatClock(progress.positionMs)} watched'
                  : (item.fileSize > 0
                      ? TelegramStreamService.formatBytes(item.fileSize)
                      : 'Tap to stream');
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _openVideo(item, directResume: hasProgress),
                child: Container(
                  width: 240,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _kCardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: hasProgress
                          ? _kAccent.withValues(alpha: 0.35)
                          : _kCardBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 48,
                          height: 62,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _buildThumbnailWidget(
                                item,
                                fallback: Container(color: _kSurfaceLight),
                              ),
                              Container(
                                color: Colors.black.withValues(alpha: 0.3),
                              ),
                              const Center(
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  color: _kAccent,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _kTextPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    hasProgress ? _kAccent : _kTextSecondary,
                                fontSize: 11,
                                fontWeight: hasProgress
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                            if (hasProgress && progress.fraction > 0) ...[
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress.fraction,
                                  minHeight: 2.5,
                                  backgroundColor: _kSurfaceLight,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    _kAccent,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (isSaved)
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Remove',
                          icon: const Icon(
                            Icons.close_rounded,
                            color: _kTextSecondary,
                            size: 16,
                          ),
                          onPressed: () async {
                            await TelegramStreamService.instance
                                .removeManualVideo(item.streamUrl);
                            await _loadInitial();
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _buildSectionHeader(String title, {int? count, Widget? trailing}) {
    return Row(
      children: [
        Container(
          width: 3.5,
          height: 16,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: _kAccent,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Text(
          title,
          style: const TextStyle(
            color: _kTextPrimary,
            fontSize: 15.5,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (count != null && count > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kAccent.withValues(alpha: 0.3)),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: _kAccent,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (trailing != null) trailing,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSearchingText = _searchController.text.trim().isNotEmpty;
    final gridVideos = _botVideos;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searchFocusNode.hasFocus || _searchController.text.isNotEmpty) {
          _searchFocusNode.unfocus();
          FocusScope.of(context).unfocus();
          if (_searchController.text.isNotEmpty) {
            _searchController.clear();
            _onSearchChanged('');
          }
          return;
        }
        Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: _kBgColor,
        appBar: AppBar(
          backgroundColor: _kBgColor,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          iconTheme: const IconThemeData(color: _kTextPrimary),
          title: const Text(
            'Stream',
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: _resolvingCode ? null : _showStreamCodeDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _kAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _kAccent.withValues(alpha: 0.45)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_resolvingCode)
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: _kAccent,
                          ),
                        )
                      else
                        const Icon(
                          Icons.vpn_key_rounded,
                          color: _kAccent,
                          size: 14,
                        ),
                      const SizedBox(width: 5),
                      Text(
                        _resolvingCode ? 'Loading...' : 'Code',
                        style: const TextStyle(
                          color: _kAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Open Telegram Bot',
              icon: const Icon(
                Icons.send_rounded,
                color: _kTextPrimary,
                size: 19,
              ),
              onPressed: _openBotInTelegram,
            ),
          ],
        ),
        body: ColoredBox(
          color: _kBgColor,
          child: RefreshIndicator(
            color: _kAccent,
            backgroundColor: _kCardBg,
            onRefresh: _loadInitial,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (_resolvingCode)
                  const SliverToBoxAdapter(
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: _kAccent,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                // Top Search Bar
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: _kInputBg,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: _kCardBorder),
                            ),
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              style: const TextStyle(
                                color: _kTextPrimary,
                                fontSize: 13.5,
                              ),
                              onChanged: _onSearchChanged,
                              decoration: InputDecoration(
                                hintText: 'Search movies or files...',
                                hintStyle: const TextStyle(
                                  color: _kTextSecondary,
                                ),
                                border: InputBorder.none,
                                icon: const Icon(
                                  Icons.search_rounded,
                                  color: _kAccent,
                                  size: 20,
                                ),
                                suffixIcon: isSearchingText
                                    ? IconButton(
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          color: _kTextSecondary,
                                          size: 18,
                                        ),
                                        onPressed: () {
                                          _searchController.clear();
                                          _onSearchChanged('');
                                        },
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (isSearchingText) ...[
                  if (_searching)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildShimmerGrid(count: 4),
                      ),
                    )
                  else ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: _buildSectionHeader(
                          'Matching Movies',
                          count: _matchingVideos.length,
                        ),
                      ),
                    ),
                    if (_matchingVideos.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 24,
                            ),
                            decoration: BoxDecoration(
                              color: _kCardBg,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _kCardBorder),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.search_off_rounded,
                                  color: _kTextSecondary,
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No matching movies found for "${_searchController.text.trim()}".',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _kTextSecondary,
                                    fontSize: 12.5,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextButton(
                                  onPressed: () {
                                    _searchController.clear();
                                    _onSearchChanged('');
                                  },
                                  child: const Text(
                                    'Clear Search',
                                    style: TextStyle(
                                      color: _kAccent,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.84,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (_, idx) => _buildMovieGridCard(
                              _matchingVideos[idx],
                              canDelete: _isOwner,
                            ),
                            childCount: _matchingVideos.length,
                          ),
                        ),
                      ),

                    if (_matchingMovies.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSectionHeader(
                                'Movies DB',
                                count: _matchingMovies.length,
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 196,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _matchingMovies.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 10),
                                  itemBuilder: (_, idx) =>
                                      _buildMovieCard(_matchingMovies[idx]),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ] else ...[
                  if (_loadingFeed) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: _buildSectionHeader('Movies'),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildShimmerGrid(count: 6),
                      ),
                    ),
                  ] else ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildContinueWatchStrip(),
                      ),
                    ),
                    if (_feedError != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _buildErrorBanner(),
                        ),
                      )
                    else ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: _buildSectionHeader(
                            'Movies',
                            count: gridVideos.length,
                            trailing: IconButton(
                              tooltip: 'Refresh',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(
                                Icons.refresh_rounded,
                                color: _kTextSecondary,
                                size: 20,
                              ),
                              onPressed: _loadInitial,
                            ),
                          ),
                        ),
                      ),
                      if (gridVideos.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            child: _buildEmptyState(),
                          ),
                        )
                      else ...[
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 0.84,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (_, idx) => _buildMovieGridCard(
                                gridVideos[idx],
                                canDelete: _isOwner,
                              ),
                              childCount: gridVideos.length,
                            ),
                          ),
                        ),
                        if (_loadingMore)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                16,
                              ),
                              child: _buildShimmerGrid(count: 2),
                            ),
                          ),
                      ],
                    ],
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
