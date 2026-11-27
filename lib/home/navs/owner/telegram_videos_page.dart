import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/services/video_frame_thumbnail_service.dart';
import 'package:mrdb/widgets/mkv_stream_player_page.dart';
import 'package:mrdb/widgets/movie_collection_sheets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

class TelegramVideosPage extends StatefulWidget {
  final List<TelegramVideoItem>? initialBotVideos;

  const TelegramVideosPage({super.key, this.initialBotVideos});

  @override
  State<TelegramVideosPage> createState() => _TelegramVideosPageState();
}

class _TelegramVideosPageState extends State<TelegramVideosPage> {
  static const Color _kBgColor = Color(0xFF000000);
  static const Color _kCardBg = Color(0xFF10131C);
  static const Color _kSheetBg = Color(0xFF121622);
  static const Color _kSurfaceLight = Color(0xFF171C2A);
  static const Color _kInputBg = Color(0xFF0D1018);
  static const Color _kCardBorder = Color(0xFF1E2434);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kAccentCyan = Color(0xFF00B0FF);
  static const Color _kGoldAccent = Color(0xFFF5C451);
  static const Color _kDanger = Color(0xFFFF6B6B);
  static const Color _kTextPrimary = Color(0xFFF5F7FA);
  static const Color _kTextSecondary = Color(0xFF8E97AB);

  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;

  bool _loadingFeed = true;
  bool _refreshingFeed = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextOffset = 0;
  bool _resolvingCode = false;
  bool _searching = false;
  bool _isOwner = false;
  bool _ownerUserPreviewMode = false;
  bool get _effectiveOwnerMode => _isOwner && !_ownerUserPreviewMode;
  bool _searchFocused = false;
  String? _feedError;

  List<TelegramVideoItem> _botVideos = [];
  List<TelegramVideoItem> _matchingVideos = [];
  List<Map<String, dynamic>> _matchingMovies = [];
  List<TelegramVideoItem> _savedLinks = [];
  Map<String, VideoWatchProgress> _progressMap = {};
  Map<String, String> _capturedFrames = {};
  Map<String, String> _lastWatchedFrames = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    VideoFrameThumbnailService.instance.addListener(_onFrameExtracted);
    if (widget.initialBotVideos != null) {
      _botVideos = widget.initialBotVideos!;
      _loadingFeed = false;
      _hasMore = false;
    } else {
      _loadInitial();
    }
  }

  @override
  void dispose() {
    VideoFrameThumbnailService.instance.removeListener(_onFrameExtracted);
    _searchDebounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _codeController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (_searchFocused != _searchFocusNode.hasFocus) {
      setState(() => _searchFocused = _searchFocusNode.hasFocus);
    }
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

  void _showFeedback(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final accent = isError ? _kDanger : _kAccent;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: _kSheetBg,
          elevation: 6,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: accent.withValues(alpha: 0.45)),
          ),
          content: Row(
            children: [
              Icon(
                isError
                    ? Icons.info_outline_rounded
                    : Icons.check_circle_rounded,
                color: accent,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  Future<void> _loadInitial({bool showFullLoading = false}) async {
    VideoFrameThumbnailService.instance.clearFailedCache();
    final useFullLoader =
        showFullLoading || (_botVideos.isEmpty && _savedLinks.isEmpty);
    setState(() {
      if (useFullLoader) {
        _loadingFeed = true;
      } else {
        _refreshingFeed = true;
      }
      _feedError = null;
      _hasMore = true;
      _nextOffset = 0;
    });
    final prefs = await SharedPreferences.getInstance();
    final isOwner = prefs.getBool('is_owner') ?? false;
    final includeHidden = isOwner && !_ownerUserPreviewMode;
    final results = await Future.wait([
      TelegramStreamService.instance.fetchBotVideos(
        limit: 10,
        offset: 0,
        includeHidden: includeHidden,
      ),
      TelegramStreamService.instance.getSavedManualVideos(),
      TelegramStreamService.instance.getAllWatchProgress(),
      TelegramStreamService.instance.getAllCapturedFrames(),
      TelegramStreamService.instance.getAllLastFrames(),
    ]);
    final feed = results[0] as TelegramVideosResult;
    final saved = results[1] as List<TelegramVideoItem>;
    final progress = results[2] as Map<String, VideoWatchProgress>;
    final captured = results[3] as Map<String, String>;
    final lastFrames = results[4] as Map<String, String>;
    final dedupedFeed = TelegramStreamService.dedupeVideos(feed.videos);
    final uniqueSaved = _filterUniqueSaved(saved, dedupedFeed);
    if (!mounted) return;
    setState(() {
      _botVideos = dedupedFeed;
      _feedError = feed.errorMessage;
      _hasMore = feed.hasMore;
      _nextOffset = feed.rawCount > 0 ? feed.rawCount : dedupedFeed.length;
      _savedLinks = uniqueSaved;
      _progressMap = progress;
      _capturedFrames = captured;
      _lastWatchedFrames = lastFrames;
      _isOwner = isOwner;
      _loadingFeed = false;
      _refreshingFeed = false;
    });
  }

  List<TelegramVideoItem> _filterUniqueSaved(
    List<TelegramVideoItem> saved,
    List<TelegramVideoItem> feed,
  ) {
    final feedMsgIds = feed.map((v) => v.msgId).whereType<int>().toSet();
    final feedCodes = feed
        .map((v) => v.streamCode.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toSet();
    final feedUrls = feed.map((v) => v.streamUrl.trim()).toSet();
    final feedFileNames = feed
        .map((v) => v.fileName.trim().toLowerCase())
        .where((f) => f.isNotEmpty)
        .toSet();
    final feedTitles = feed
        .map((v) => v.title.trim().toLowerCase())
        .where((t) => t.isNotEmpty)
        .toSet();
    return TelegramStreamService.dedupeVideos(saved).where((v) {
      if (v.msgId != null && feedMsgIds.contains(v.msgId)) return false;
      final code = v.streamCode.trim().toUpperCase();
      if (code.isNotEmpty && feedCodes.contains(code)) return false;
      if (feedUrls.contains(v.streamUrl.trim())) return false;
      final fn = v.fileName.trim().toLowerCase();
      if (fn.isNotEmpty && feedFileNames.contains(fn)) return false;
      final t = v.title.trim().toLowerCase();
      if (t.isNotEmpty && feedTitles.contains(t)) return false;
      return true;
    }).toList();
  }

  Future<void> _refreshProgress() async {
    final results = await Future.wait([
      TelegramStreamService.instance.getAllWatchProgress(),
      TelegramStreamService.instance.getAllCapturedFrames(),
      TelegramStreamService.instance.getAllLastFrames(),
    ]);
    if (!mounted) return;
    setState(() {
      _progressMap = results[0] as Map<String, VideoWatchProgress>;
      _capturedFrames = results[1] as Map<String, String>;
      _lastWatchedFrames = results[2] as Map<String, String>;
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
      limit: 10,
      offset: _nextOffset,
      includeHidden: _effectiveOwnerMode,
    );
    if (!mounted) return;
    final merged = TelegramStreamService.dedupeVideos([
      ..._botVideos,
      ...res.videos,
    ]);
    setState(() {
      _botVideos = merged;
      _savedLinks = _filterUniqueSaved(_savedLinks, merged);
      _nextOffset += res.rawCount > 0 ? res.rawCount : res.videos.length;
      _hasMore = res.hasMore && res.rawCount > 0;
      _loadingMore = false;
    });
  }

  Future<void> _playByCode() async {
    final input = _codeController.text.trim();
    if (input.isEmpty) {
      _showFeedback('Enter a stream code from the bot', isError: true);
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
      _showFeedback(
        lookup.errorMessage ?? 'Could not find that stream code',
        isError: true,
      );
      return;
    }

    await TelegramStreamService.instance.saveManualVideo(lookup.video!);
    _codeController.clear();
    final resolved = lookup.video!;
    final alreadyInFeed = _botVideos.any(
      (v) =>
          v.streamUrl.trim() == resolved.streamUrl.trim() ||
          (resolved.streamCode.trim().isNotEmpty &&
              v.streamCode.trim().toUpperCase() ==
                  resolved.streamCode.trim().toUpperCase()),
    );
    if (!alreadyInFeed &&
        !_savedLinks.any((v) => v.streamUrl.trim() == resolved.streamUrl.trim())) {
      setState(() {
        _savedLinks = [resolved, ..._savedLinks];
      });
    }
    if (mounted) {
      _openVideo(resolved);
    }
  }

  Future<void> _showStreamCodeSheet() async {
    HapticFeedback.lightImpact();
    String? inlineError;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final bottomInset = MediaQuery.viewInsetsOf(sheetCtx).bottom;
          final hasText = _codeController.text.trim().isNotEmpty;

          Future<void> submit() async {
            if (_codeController.text.trim().isEmpty) {
              setSheetState(() {
                inlineError = 'Paste or type a stream code first (e.g. MRDB-...)';
              });
              return;
            }
            Navigator.pop(sheetCtx);
            await _playByCode();
          }

          return Container(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
            decoration: const BoxDecoration(
              color: _kSheetBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              border: Border(
                top: BorderSide(color: _kCardBorder, width: 1.2),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _kAccent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _kAccent.withValues(alpha: 0.32),
                          ),
                        ),
                        child: const Icon(
                          Icons.vpn_key_rounded,
                          color: _kAccent,
                          size: 19,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Stream with Code',
                              style: TextStyle(
                                color: _kTextPrimary,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Paste an MRDB code from @FileToSpeedLink_Bot',
                              style: TextStyle(
                                color: _kTextSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(sheetCtx),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _kTextSecondary,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
                    decoration: BoxDecoration(
                      color: _kInputBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: inlineError != null
                            ? _kDanger.withValues(alpha: 0.7)
                            : _kAccent.withValues(alpha: 0.35),
                        width: 1.1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            autofocus: true,
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                            textCapitalization: TextCapitalization.characters,
                            textInputAction: TextInputAction.go,
                            onChanged: (_) {
                              setSheetState(() {
                                if (inlineError != null) inlineError = null;
                              });
                            },
                            onSubmitted: (_) => submit(),
                            decoration: const InputDecoration(
                              hintText: 'MRDB-123-ABC...',
                              hintStyle: TextStyle(color: _kTextSecondary),
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        if (hasText)
                          IconButton(
                            tooltip: 'Clear',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: _kTextSecondary,
                              size: 18,
                            ),
                            onPressed: () {
                              _codeController.clear();
                              setSheetState(() => inlineError = null);
                            },
                          ),
                        const SizedBox(width: 4),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: _kAccent,
                            backgroundColor: _kAccent.withValues(alpha: 0.12),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () async {
                            final pasted = await _pasteFromClipboard();
                            if (pasted) {
                              setSheetState(() => inlineError = null);
                            }
                          },
                          icon: const Icon(
                            Icons.content_paste_rounded,
                            size: 15,
                          ),
                          label: const Text(
                            'Paste',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (inlineError != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: _kDanger,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            inlineError!,
                            style: const TextStyle(
                              color: _kDanger,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _kTextPrimary,
                            backgroundColor: _kSurfaceLight.withValues(
                              alpha: 0.55,
                            ),
                            elevation: 0,
                            side: const BorderSide(color: _kCardBorder),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 13,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _openBotInTelegram,
                          icon: const Icon(Icons.send_rounded, size: 15),
                          label: const Text(
                            'Open Bot',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 3,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kAccent,
                            foregroundColor: const Color(0xFF04140F),
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 13,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: submit,
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                          label: const Text(
                            'Stream Now',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<bool> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showFeedback('Clipboard is empty', isError: true);
      return false;
    }
    _codeController.text = text;
    _codeController.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
    return true;
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
        TelegramStreamService.instance.fetchBotVideos(
          query: q,
          limit: 30,
          includeHidden: _effectiveOwnerMode,
        ),
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
            highlightColor: const Color(0xFF252C40),
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

  String? _existingFramePath(String? path) {
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  String? _lastFramePathFor(String key) {
    return _existingFramePath(_lastWatchedFrames[key]) ??
        _existingFramePath(_capturedFrames[key]) ??
        _existingFramePath(VideoFrameThumbnailService.instance.pathFor(key));
  }

  Widget _buildContinueFrameWidget(
    TelegramVideoItem item, {
    BoxFit fit = BoxFit.cover,
    Widget? fallback,
  }) {
    final key = TelegramStreamService.progressKeyFor(item);
    final lastPath = _existingFramePath(_lastWatchedFrames[key]);
    if (lastPath != null) {
      return Image.file(
        File(lastPath),
        key: ValueKey<String>(lastPath),
        fit: fit,
        errorBuilder: (_, _, _) =>
            _buildThumbnailWidget(item, fit: fit, fallback: fallback),
      );
    }
    return _buildThumbnailWidget(item, fit: fit, fallback: fallback);
  }

  String _formatDurationWords(int ms) {
    final totalMin = (ms / 60000).ceil().clamp(1, 9999);
    if (totalMin < 60) return '$totalMin min left';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return m > 0 ? '${h}h ${m}m left' : '${h}h left';
  }

  Future<String?> _showResumeSheet(
    TelegramVideoItem item,
    VideoWatchProgress progress,
  ) {
    final key = TelegramStreamService.progressKeyFor(item);
    final lastFramePath = _existingFramePath(_lastWatchedFrames[key]);
    final fallbackFramePath = _lastFramePathFor(key);
    final hasAnyFrame = lastFramePath != null ||
        fallbackFramePath != null ||
        (item.thumbUrl?.trim().isNotEmpty ?? false);

    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ContinueWatchResumeSheet(
        title: _friendlyTitle(item),
        quality: _extractQualityLabel(item),
        clock: _formatClock(progress.positionMs),
        totalClock: progress.durationMs > 0
            ? _formatClock(progress.durationMs)
            : null,
        remainingLabel: progress.durationMs > progress.positionMs
            ? _formatDurationWords(progress.durationMs - progress.positionMs)
            : null,
        fraction: progress.fraction > 0 ? progress.fraction : 0.08,
        hasLastFrame: lastFramePath != null,
        hasAnyFrame: hasAnyFrame,
        previewChild: _buildContinueFrameWidget(
          item,
          fit: BoxFit.cover,
          fallback: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A2236), Color(0xFF0E121D)],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.movie_rounded,
                color: Colors.white.withValues(alpha: 0.22),
                size: 40,
              ),
            ),
          ),
        ),
        onClose: () => Navigator.pop(ctx),
        onStartOver: () => Navigator.pop(ctx, 'start_over'),
        onResume: () => Navigator.pop(ctx, 'resume'),
      ),
    );
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
        final choice = await _showResumeSheet(item, progress);
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
    final localThumbPath = _lastFramePathFor(key);
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
          thumbnailUrl: item.thumbUrl,
          thumbnailPath: localThumbPath,
          disabledAudioIndices: item.disabledAudioIndices,
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
    HapticFeedback.lightImpact();
    final uri = Uri.parse('https://t.me/FileToSpeedLink_Bot');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _showFeedback('Could not open Telegram', isError: true);
    }
  }

  static final RegExp _extRegex = RegExp(
    r'\.(mkv|mp4|avi|mov|webm|m4v|ts|flv)$',
    caseSensitive: false,
  );

  String _friendlyTitle(TelegramVideoItem item) {
    if (item.metadataEdited && item.title.trim().isNotEmpty) {
      return item.title.trim();
    }
    final source = item.fileName.trim().isNotEmpty
        ? item.fileName
        : item.title;
    final raw = source
        .replaceFirst(_extRegex, '')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return raw.isEmpty ? 'Movie Video' : raw;
  }

  void _replaceVideoItem(TelegramVideoItem updated) {
    bool matches(TelegramVideoItem v) =>
        (updated.msgId != null && v.msgId == updated.msgId) ||
        v.streamUrl.trim() == updated.streamUrl.trim() ||
        (updated.streamCode.isNotEmpty &&
            v.streamCode.toUpperCase() == updated.streamCode.toUpperCase());

    setState(() {
      _botVideos = [
        for (final v in _botVideos) matches(v) ? updated : v,
      ];
      _matchingVideos = [
        for (final v in _matchingVideos) matches(v) ? updated : v,
      ];
      _savedLinks = [
        for (final v in _savedLinks) matches(v) ? updated : v,
      ];
    });
  }

  Future<void> _addVideoToCollection(TelegramVideoItem item) async {
    if (!_isOwner) return;
    HapticFeedback.lightImpact();
    final cleanMovieName = TelegramStreamService.analyzeFileNameLocally(
      item.fileName,
      existingTitle: item.title,
    ).searchQuery;
    final selected = await showTmdbMoviePickerSheet(
      context,
      initialQuery: cleanMovieName.isNotEmpty
          ? cleanMovieName
          : TelegramStreamService.cleanSearchTitle(item.fileName),
      fileLabel: _friendlyTitle(item),
      currentTmdbId: item.tmdbId,
      currentTmdbTitle: item.tmdbTitle,
      videoItem: item,
      isOwner: _isOwner,
    );
    if (selected == null || !mounted) return;
    if (selected.unlink) {
      final updated = await TelegramStreamService.instance.updateBotVideoMetadata(
        item,
        clearTmdb: true,
      );
      if (!mounted) return;
      if (updated != null) {
        _replaceVideoItem(updated);
        _showFeedback('Removed movie link from collection');
      } else {
        _showFeedback('Could not unlink movie from collection', isError: true);
      }
      return;
    }
    final updated = await TelegramStreamService.instance.updateBotVideoMetadata(
      item,
      tmdbId: selected.id,
      tmdbTitle: selected.title,
      tmdbPoster: selected.posterPath,
      tmdbYear: selected.releaseYear,
    );
    if (!mounted) return;
    if (updated != null) {
      _replaceVideoItem(updated);
      _showFeedback('Linked to "${selected.title}" for all users');
    } else {
      _showFeedback('Could not link movie to collection', isError: true);
    }
  }

  Future<void> _editBotVideoMetadata(TelegramVideoItem item) async {
    if (!_isOwner) return;
    HapticFeedback.lightImpact();
    final updated = await showEditMovieMetadataSheet(
      context,
      item: item,
      onRequestDelete: () => _confirmDeleteBotVideo(item),
    );
    if (updated == null || !mounted) return;
    _replaceVideoItem(updated);
    _showFeedback('Updated details for all users');
  }

  Future<void> _toggleHiddenForUsers(TelegramVideoItem item) async {
    if (!_isOwner) return;
    final nextHidden = !item.hiddenForUsers;
    final updated = await TelegramStreamService.instance.updateBotVideoMetadata(
      item,
      hiddenForUsers: nextHidden,
    );
    if (!mounted) return;
    if (updated != null) {
      _replaceVideoItem(updated);
      _showFeedback(
        nextHidden
            ? 'Hidden from users (Owner only)'
            : 'Visible to all users',
      );
    } else {
      _showFeedback('Could not update visibility', isError: true);
    }
  }

  Future<void> _showOwnerCardOptionsSheet(TelegramVideoItem item) async {
    if (!_effectiveOwnerMode) return;
    HapticFeedback.lightImpact();
    final title = _friendlyTitle(item);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
        ),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
        decoration: const BoxDecoration(
          color: _kSheetBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: _kCardBorder, width: 1.2)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _kTextPrimary,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.streamCode.isNotEmpty
                    ? '${item.streamCode} • ${item.formatBadge}'
                    : item.formatBadge,
                style: const TextStyle(
                  color: _kTextSecondary,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 12),
              _buildOwnerActionTile(
                icon: Icons.tune_rounded,
                color: _kAccent,
                title: 'Edit Name, Metadata & Audio',
                subtitle: 'Rename file, edit quality/year/language, remove audio',
                onTap: () {
                  Navigator.pop(ctx);
                  _editBotVideoMetadata(item);
                },
              ),
              _buildOwnerActionTile(
                icon: item.tmdbId != null
                    ? Icons.library_add_check_rounded
                    : Icons.library_add_rounded,
                color: _kAccentCyan,
                title: item.tmdbId != null
                    ? 'Change / Unlink TMDB Movie'
                    : 'Add to Movie Collection (TMDB)',
                subtitle: item.tmdbTitle?.isNotEmpty == true
                    ? 'Linked: ${item.tmdbTitle}'
                    : 'Link this file to a TMDB movie preview page',
                onTap: () {
                  Navigator.pop(ctx);
                  _addVideoToCollection(item);
                },
              ),
              if (item.streamCode.isNotEmpty)
                _buildOwnerActionTile(
                  icon: Icons.copy_rounded,
                  color: _kTextPrimary,
                  title: 'Copy Stream Code',
                  subtitle: item.streamCode,
                  onTap: () {
                    Navigator.pop(ctx);
                    _copyStreamCode(item);
                  },
                ),
              if (item.watchUrl != null && item.watchUrl!.trim().isNotEmpty)
                _buildOwnerActionTile(
                  icon: Icons.open_in_browser_rounded,
                  color: _kGoldAccent,
                  title: 'Open Watch Page in Browser',
                  subtitle: 'Preview web stream link',
                  onTap: () async {
                    Navigator.pop(ctx);
                    final uri = Uri.tryParse(item.watchUrl!.trim());
                    if (uri != null) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                ),
              _buildOwnerActionTile(
                icon: item.hiddenForUsers
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                color: _kGoldAccent,
                title: item.hiddenForUsers
                    ? 'Show to All Users'
                    : 'Hide from Users (Owner Only)',
                subtitle: item.hiddenForUsers
                    ? 'Currently hidden from regular users'
                    : 'Only visible when browsing in Owner mode',
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleHiddenForUsers(item);
                },
              ),
              _buildOwnerActionTile(
                icon: Icons.delete_outline_rounded,
                color: _kDanger,
                title: 'Remove from Stream',
                subtitle: 'Delete this movie from the Stream library',
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteBotVideo(item);
                },
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOwnerActionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: color, size: 19),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: _kTextPrimary,
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _kTextSecondary, fontSize: 11.5),
      ),
      onTap: onTap,
    );
  }

  Future<void> _confirmDeleteBotVideo(TelegramVideoItem item) async {
    HapticFeedback.lightImpact();
    final title = _friendlyTitle(item);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: const BoxDecoration(
          color: _kSheetBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          border: Border(top: BorderSide(color: _kCardBorder, width: 1.2)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: _kDanger.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: _kDanger,
                  size: 24,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Remove from Stream?',
                style: TextStyle(
                  color: _kTextPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '"$title" will be removed from the Stream library.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _kTextSecondary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kTextPrimary,
                        backgroundColor: _kSurfaceLight.withValues(alpha: 0.5),
                        side: const BorderSide(color: _kCardBorder),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kDanger,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shadowColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        'Remove',
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
      _showFeedback('Movie removed from Stream');
    } else {
      _showFeedback('Could not delete movie from server', isError: true);
    }
  }

  String _extractQualityLabel(TelegramVideoItem item) {
    final q = item.quality?.trim() ?? '';
    if (q.isNotEmpty) return q.toUpperCase();
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
    final yearStr = item.year?.toString() ?? yearMatch?.group(0);

    if (progress != null && progress.positionMs >= 3000) {
      return '${_formatClock(progress.positionMs)} watched';
    }

    final parts = <String>[
      if (yearStr != null) yearStr,
      if (item.language != null && item.language!.trim().isNotEmpty)
        item.language!.trim(),
      if (item.fileSize > 0) TelegramStreamService.formatBytes(item.fileSize),
    ];
    if (parts.isEmpty) return 'Tap to play';
    return parts.join(' • ');
  }

  Future<void> _copyStreamCode(TelegramVideoItem item) async {
    final code = item.streamCode.trim();
    if (code.isEmpty) return;
    HapticFeedback.mediumImpact();
    await Clipboard.setData(ClipboardData(text: code));
    _showFeedback('Stream code copied: $code');
  }

  void _openMoviePreviewFromItem(TelegramVideoItem item) {
    final tmdbId = item.tmdbId;
    if (tmdbId == null || tmdbId <= 0) return;
    final movieTitle = (item.tmdbTitle != null &&
            item.tmdbTitle!.trim().isNotEmpty &&
            item.tmdbTitle!.trim().toLowerCase() != 'null')
        ? item.tmdbTitle!.trim()
        : _friendlyTitle(item);
    final poster = (item.tmdbPoster ?? '').trim();
    final hasPoster = poster.isNotEmpty && poster.toLowerCase() != 'null';
    final yearText = (item.tmdbYear ?? item.year?.toString() ?? '').trim();
    final overviewText = (item.overview ?? '').trim();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MoviePreview(
          movieId: tmdbId,
          initialMovie: {
            'id': tmdbId,
            'title': movieTitle,
            if (hasPoster) 'poster_path': poster,
            if (yearText.isNotEmpty) 'release_date': yearText,
            if (overviewText.isNotEmpty) 'overview': overviewText,
          },
          posterPath: hasPoster ? poster : null,
          title: movieTitle,
        ),
      ),
    );
  }

  Future<void> _showCollectionMovieInfoDialog(TelegramVideoItem item) async {
    final tmdbId = item.tmdbId;
    if (tmdbId == null || tmdbId <= 0) return;
    final movieTitle = (item.tmdbTitle != null &&
            item.tmdbTitle!.trim().isNotEmpty &&
            item.tmdbTitle!.trim().toLowerCase() != 'null')
        ? item.tmdbTitle!.trim()
        : _friendlyTitle(item);
    final poster = (item.tmdbPoster ?? '').trim();
    final hasPoster = poster.isNotEmpty && poster.toLowerCase() != 'null';
    final posterUrl = hasPoster
        ? (poster.startsWith('http')
            ? poster
            : '${AppConstants.baseImageUrl}$poster')
        : null;
    final yearStr = (item.tmdbYear ?? item.year?.toString() ?? '').trim();
    final quality = _extractQualityLabel(item);
    final langStr = (item.language ?? '').trim();
    final sizeStr =
        item.fileSize > 0 ? TelegramStreamService.formatBytes(item.fileSize) : '';
    final overviewText = (item.overview ?? '').trim();
    final metaLine = [
      if (yearStr.isNotEmpty) yearStr,
      if (langStr.isNotEmpty) langStr,
      quality,
      if (sizeStr.isNotEmpty) sizeStr,
    ].join(' • ');

    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.58),
        barrierLabel: 'Dismiss Movie Card',
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 190),
        pageBuilder: (cardCtx, _, _) {
          return SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      decoration: BoxDecoration(
                        color: _kCardBg,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _kCardBorder,
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.65),
                            blurRadius: 28,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Center(
                              child: Container(
                                width: 34,
                                height: 4,
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    width: 68,
                                    height: 98,
                                    color: _kSurfaceLight,
                                    child: posterUrl != null
                                        ? CachedNetworkImage(
                                            imageUrl: posterUrl,
                                            fit: BoxFit.cover,
                                            errorWidget: (_, _, _) => const Icon(
                                              Icons.movie_rounded,
                                              color: _kTextSecondary,
                                              size: 28,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.movie_rounded,
                                            color: _kTextSecondary,
                                            size: 28,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              movieTitle,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: _kTextPrimary,
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                                height: 1.2,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () => Navigator.pop(cardCtx),
                                            child: Tooltip(
                                              message: 'Close',
                                              child: Container(
                                                padding: const EdgeInsets.all(4),
                                                decoration: BoxDecoration(
                                                  color: _kSurfaceLight,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: const Icon(
                                                  Icons.close_rounded,
                                                  color: _kTextSecondary,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (metaLine.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          metaLine,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: _kAccent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              overviewText.isNotEmpty
                                  ? overviewText
                                  : 'Added to MRDb collection. Open movie profile for full details, cast, and trailers.',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _kTextSecondary,
                                fontSize: 12.8,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _kAccent,
                                  foregroundColor: const Color(0xFF04140F),
                                  elevation: 0,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 13,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.pop(cardCtx);
                                  _openMoviePreviewFromItem(item);
                                },
                                icon: const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 18,
                                ),
                                label: const Text(
                                  'View Profile',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        transitionsBuilder: (ctx, animation, secondaryAnimation, child) {
          final slideAnim = Tween<Offset>(
            begin: const Offset(0, 0.14),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
          );
          final fadeAnim = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOut,
          );
          return FadeTransition(
            opacity: fadeAnim,
            child: SlideTransition(
              position: slideAnim,
              child: child,
            ),
          );
        },
      ),
    );
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: hasProgress ? _kAccent.withValues(alpha: 0.48) : _kCardBorder,
          width: hasProgress ? 1.2 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openVideo(item),
            onLongPress: canDelete
                ? () => _showOwnerCardOptionsSheet(item)
                : () => _copyStreamCode(item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 11,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildThumbnailWidget(
                        item,
                        fallback: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF1A2034), Color(0xFF10131E)],
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.movie_rounded,
                              color: Colors.white.withValues(alpha: 0.22),
                              size: 34,
                            ),
                          ),
                        ),
                      ),
                      // Smooth gradient scrim into card body
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.14),
                                Colors.transparent,
                                _kCardBg.withValues(alpha: 0.90),
                              ],
                              stops: const [0.0, 0.55, 1.0],
                            ),
                          ),
                        ),
                      ),
                      // Quality pill (top-left)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                          ),
                          child: Text(
                            quality,
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ),
                      if (item.hiddenForUsers)
                        Positioned(
                          left: 8,
                          bottom: hasProgress ? 9 : 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: _kGoldAccent.withValues(alpha: 0.55),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.visibility_off_rounded,
                                  color: _kGoldAccent,
                                  size: 11,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Hidden',
                                  style: TextStyle(
                                    color: _kGoldAccent,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // Collection movie info + Owner collection link & options (top-right)
                      if ((item.tmdbId != null && item.tmdbId! > 0) || canDelete)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (item.tmdbId != null && item.tmdbId! > 0)
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _showCollectionMovieInfoDialog(item),
                                  child: Tooltip(
                                    message: 'Movie Info',
                                    child: Container(
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.76),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _kAccentCyan.withValues(alpha: 0.65),
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.info_outline_rounded,
                                        color: _kAccentCyan,
                                        size: 14.5,
                                      ),
                                    ),
                                  ),
                                ),
                              if (canDelete) ...[
                                if (item.tmdbId != null && item.tmdbId! > 0)
                                  const SizedBox(width: 4),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _addVideoToCollection(item),
                                  child: Tooltip(
                                    message: item.tmdbId != null
                                        ? 'Linked to Movie'
                                        : 'Add to Collection',
                                    child: Container(
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: item.tmdbId != null
                                            ? _kAccent.withValues(alpha: 0.92)
                                            : Colors.black.withValues(alpha: 0.72),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: item.tmdbId != null
                                              ? _kAccent
                                              : Colors.white.withValues(alpha: 0.14),
                                        ),
                                      ),
                                      child: Icon(
                                        item.tmdbId != null
                                            ? Icons.library_add_check_rounded
                                            : Icons.library_add_rounded,
                                        color: item.tmdbId != null
                                            ? const Color(0xFF04140F)
                                            : _kTextPrimary,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _showOwnerCardOptionsSheet(item),
                                  child: Tooltip(
                                    message: 'Owner Options',
                                    child: Container(
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.72),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white.withValues(alpha: 0.14),
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.more_horiz_rounded,
                                        color: _kAccent,
                                        size: 15,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      // Friendly Play chip (bottom-right) leaving scene clear
                      Positioned(
                        right: 8,
                        bottom: hasProgress ? 9 : 7,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: _kAccent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: _kAccent.withValues(alpha: 0.35),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Color(0xFF04140F),
                            size: 20,
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
                Expanded(
                  flex: 7,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 7, 11, 10),
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
                        Row(
                          children: [
                            if (hasProgress) ...[
                              Container(
                                width: 6,
                                height: 6,
                                margin: const EdgeInsets.only(right: 5),
                                decoration: const BoxDecoration(
                                  color: _kAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                            Expanded(
                              child: Text(
                                sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: hasProgress ? _kAccent : _kTextSecondary,
                                  fontSize: 11,
                                  fontWeight: hasProgress
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
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
      width: 108,
      height: 152,
      decoration: BoxDecoration(
        color: _kSurfaceLight,
        borderRadius: BorderRadius.circular(14),
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
      borderRadius: BorderRadius.circular(14),
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
        width: 108,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'stream_movie_$id',
              child: Container(
                width: 108,
                height: 152,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _kCardBorder),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
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
                              horizontal: 6,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.76),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  color: _kGoldAccent,
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
      baseColor: const Color(0xFF10131C),
      highlightColor: const Color(0xFF1B2030),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.86,
        ),
        itemBuilder: (_, _) => Container(
          decoration: BoxDecoration(
            color: _kCardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _kCardBorder),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 11,
                  child: Container(color: _kSurfaceLight),
                ),
                Expanded(
                  flex: 7,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              height: 11,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: _kSurfaceLight,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              height: 11,
                              width: 78,
                              decoration: BoxDecoration(
                                color: _kSurfaceLight,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ],
                        ),
                        Container(
                          height: 9,
                          width: 64,
                          decoration: BoxDecoration(
                            color: _kSurfaceLight,
                            borderRadius: BorderRadius.circular(4),
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
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 24),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _kCardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _kAccent.withValues(alpha: 0.22),
                  _kAccentCyan.withValues(alpha: 0.14),
                ],
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: _kAccent.withValues(alpha: 0.38),
                width: 1.4,
              ),
            ),
            child: const Icon(
              Icons.play_circle_fill_rounded,
              color: _kAccent,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Ready to Stream',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 17.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Watch movies in HD with fast seek and automatic resume.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kTextSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _kInputBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kCardBorder),
            ),
            child: const Column(
              children: [
                _MiniStepRow(
                  step: '1',
                  text: 'Send any movie file to @FileToSpeedLink_Bot',
                ),
                SizedBox(height: 8),
                _MiniStepRow(
                  step: '2',
                  text: 'Copy the MRDB-... code from the bot reply',
                ),
                SizedBox(height: 8),
                _MiniStepRow(
                  step: '3',
                  text: 'Tap Enter Code below and start watching',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kTextPrimary,
                    backgroundColor: _kSurfaceLight.withValues(alpha: 0.5),
                    side: const BorderSide(color: _kCardBorder),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: _openBotInTelegram,
                  icon: const Icon(Icons.send_rounded, size: 15),
                  label: const Text(
                    'Open Bot',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kAccent,
                    foregroundColor: const Color(0xFF04140F),
                    elevation: 0,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: _showStreamCodeSheet,
                  icon: const Icon(Icons.vpn_key_rounded, size: 16),
                  label: const Text(
                    'Enter Code',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _kGoldAccent.withValues(alpha: 0.42),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _kGoldAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.wifi_off_rounded,
              color: _kGoldAccent,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _feedError ?? 'Could not reach stream server',
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'You can still play using a Stream Code.',
                  style: TextStyle(
                    color: _kTextSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: _kAccent,
              backgroundColor: _kAccent.withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: _loadInitial,
            child: const Text(
              'Retry',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeFromContinueWatch(TelegramVideoItem item) async {
    HapticFeedback.selectionClick();
    final key = TelegramStreamService.progressKeyFor(item);
    final isSaved = _savedLinks.any((s) => s.streamUrl == item.streamUrl);
    final hasProgress = _progressMap.containsKey(key);
    setState(() {
      _savedLinks.removeWhere((s) => s.streamUrl == item.streamUrl);
      _progressMap.remove(key);
      _lastWatchedFrames.remove(key);
    });
    if (isSaved) {
      await TelegramStreamService.instance.removeManualVideo(item.streamUrl);
    }
    if (hasProgress) {
      await TelegramStreamService.instance.clearWatchProgress(key);
    }
  }

  Widget _buildContinueWatchStrip() {
    final continueItems = <({TelegramVideoItem item, int timestamp})>[];
    for (final item in _savedLinks) {
      final p = _progressMap[TelegramStreamService.progressKeyFor(item)];
      final ts = p?.updatedAtMs ?? item.createdAt?.millisecondsSinceEpoch ?? 0;
      continueItems.add((item: item, timestamp: ts));
    }

    for (final item in _botVideos) {
      final matchesSaved = _savedLinks.any(
        (s) =>
            (item.msgId != null && s.msgId == item.msgId) ||
            (item.streamCode.isNotEmpty &&
                s.streamCode.toUpperCase() == item.streamCode.toUpperCase()) ||
            s.streamUrl == item.streamUrl ||
            (item.fileName.trim().isNotEmpty &&
                s.fileName.trim().toLowerCase() ==
                    item.fileName.trim().toLowerCase()),
      );
      if (matchesSaved) continue;
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
        _buildSectionHeader('Continue Watching', count: list.length),
        const SizedBox(height: 10),
        SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, idx) {
              final item = list[idx];
              final key = TelegramStreamService.progressKeyFor(item);
              final title = _friendlyTitle(item);
              final progress = _progressMap[key];
              final hasProgress =
                  progress != null && progress.positionMs >= 3000;
              final quality = _extractQualityLabel(item);
              final remainingMs = (hasProgress &&
                      progress.durationMs > progress.positionMs)
                  ? progress.durationMs - progress.positionMs
                  : 0;
              final playedText = hasProgress
                  ? (progress.durationMs > 0
                      ? 'Resume • ${_formatClock(progress.positionMs)} / ${_formatClock(progress.durationMs)}'
                      : 'Resume • ${_formatClock(progress.positionMs)}')
                  : (item.fileSize > 0
                      ? 'Saved • ${TelegramStreamService.formatBytes(item.fileSize)}'
                      : 'Ready to play');
              final double? barFraction = hasProgress
                  ? (progress.fraction > 0 ? progress.fraction : 0.14)
                  : null;

              return Container(
                width: 220,
                decoration: BoxDecoration(
                  color: _kCardBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: hasProgress
                        ? _kAccent.withValues(alpha: 0.42)
                        : _kCardBorder,
                    width: hasProgress ? 1.15 : 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.32),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _openVideo(item, directResume: hasProgress),
                      onLongPress: hasProgress ? () => _openVideo(item) : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _buildContinueFrameWidget(
                                  item,
                                  fallback: Container(
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color(0xFF1A2236),
                                          Color(0xFF0E121D),
                                        ],
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.movie_rounded,
                                      color: Colors.white.withValues(
                                        alpha: 0.22,
                                      ),
                                      size: 30,
                                    ),
                                  ),
                                ),
                                Positioned.fill(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.black.withValues(alpha: 0.34),
                                          Colors.black.withValues(alpha: 0.08),
                                          Colors.black.withValues(alpha: 0.72),
                                        ],
                                        stops: const [0.0, 0.45, 1.0],
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 8,
                                  left: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.62,
                                      ),
                                      borderRadius: BorderRadius.circular(99),
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: Text(
                                      quality,
                                      style: const TextStyle(
                                        color: _kTextPrimary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 7,
                                  right: 7,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _removeFromContinueWatch(item),
                                    child: Tooltip(
                                      message: 'Remove',
                                      child: Container(
                                        width: 26,
                                        height: 26,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.62,
                                          ),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white24,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.close_rounded,
                                          color: _kTextPrimary,
                                          size: 14,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Center(
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.56,
                                      ),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _kAccent.withValues(alpha: 0.88),
                                        width: 1.4,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: _kAccent,
                                      size: 24,
                                    ),
                                  ),
                                ),
                                if (barFraction != null)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: LinearProgressIndicator(
                                      value: barFraction,
                                      minHeight: 3.5,
                                      backgroundColor: Colors.white24,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                        _kAccent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _kTextPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        playedText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: hasProgress
                                              ? _kAccent
                                              : _kTextSecondary,
                                          fontSize: 11.5,
                                          fontWeight: hasProgress
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    if (remainingMs > 0) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        _formatDurationWords(remainingMs),
                                        style: const TextStyle(
                                          color: _kTextSecondary,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
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
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_kAccent, _kAccentCyan],
            ),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.1,
            ),
          ),
        ),
        if (count != null && count > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _kAccent.withValues(alpha: 0.28)),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: _kAccent,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
        if (trailing != null) ...[
          const Spacer(),
          trailing,
        ],
      ],
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _kBgColor,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: const IconThemeData(color: _kTextPrimary),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_kGoldAccent, _kAccent],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Color(0xFF05120D),
              size: 19,
            ),
          ),
          const SizedBox(width: 9),
          const Flexible(
            child: Text(
              'Stream',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 19.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (_isOwner)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _ownerUserPreviewMode = !_ownerUserPreviewMode);
                _loadInitial();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _effectiveOwnerMode
                      ? _kAccent.withValues(alpha: 0.16)
                      : _kSurfaceLight,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _effectiveOwnerMode
                        ? _kAccent.withValues(alpha: 0.45)
                        : _kCardBorder,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _effectiveOwnerMode
                          ? Icons.shield_rounded
                          : Icons.person_outline_rounded,
                      color: _effectiveOwnerMode ? _kAccent : _kTextSecondary,
                      size: 14,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _effectiveOwnerMode ? 'Owner' : 'User',
                      style: TextStyle(
                        color: _effectiveOwnerMode ? _kAccent : _kTextPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Refresh library',
          visualDensity: VisualDensity.compact,
          onPressed: (_loadingFeed || _refreshingFeed) ? null : _loadInitial,
          icon: Icon(
            Icons.refresh_rounded,
            color: (_loadingFeed || _refreshingFeed)
                ? _kAccent
                : _kTextSecondary,
            size: 20,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _openBotInTelegram,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
              decoration: BoxDecoration(
                color: _kSurfaceLight,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kCardBorder),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.send_rounded,
                    color: _kAccentCyan,
                    size: 14,
                  ),
                  SizedBox(width: 5),
                  Text(
                    'Bot',
                    style: TextStyle(
                      color: _kTextPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchAndCodeBar(bool isSearchingText) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: _kInputBg,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: (_searchFocused || isSearchingText)
                      ? _kAccent.withValues(alpha: 0.45)
                      : _kCardBorder,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: (_searchFocused || isSearchingText)
                          ? _kAccent.withValues(alpha: 0.16)
                          : _kSurfaceLight,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.search_rounded,
                      color: (_searchFocused || isSearchingText)
                          ? _kAccent
                          : _kTextSecondary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      style: const TextStyle(
                        color: _kTextPrimary,
                        fontSize: 13.5,
                      ),
                      onChanged: _onSearchChanged,
                      decoration: const InputDecoration(
                        hintText: 'Search movies or files...',
                        hintStyle: TextStyle(
                          color: _kTextSecondary,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  if (isSearchingText)
                    IconButton(
                      tooltip: 'Clear search',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: _kTextSecondary,
                        size: 18,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: _resolvingCode ? null : _showStreamCodeSheet,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: _kAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: _kAccent.withValues(alpha: 0.42),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_resolvingCode)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _kAccent,
                      ),
                    )
                  else
                    const Icon(
                      Icons.vpn_key_rounded,
                      color: _kAccent,
                      size: 16,
                    ),
                  const SizedBox(width: 6),
                  Text(
                    _resolvingCode ? 'Loading' : 'Code',
                    style: const TextStyle(
                      color: _kAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSearchResultSlivers() {
    if (_searching) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildShimmerGrid(count: 4),
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: _buildSectionHeader(
            'Ready to Stream',
            count: _matchingVideos.length,
          ),
        ),
      ),
      if (_matchingVideos.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              decoration: BoxDecoration(
                color: _kCardBg,
                borderRadius: BorderRadius.circular(18),
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
                  const SizedBox(height: 10),
                  Text(
                    'No stream files match "${_searchController.text.trim()}".',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Have a bot stream code? Paste it anytime.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _kTextSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                        child: const Text(
                          'Clear Search',
                          style: TextStyle(
                            color: _kTextSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAccent,
                          foregroundColor: const Color(0xFF04140F),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _showStreamCodeSheet,
                        icon: const Icon(Icons.vpn_key_rounded, size: 14),
                        label: const Text(
                          'Use Code',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
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
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.86,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, idx) => _buildMovieGridCard(
                _matchingVideos[idx],
                canDelete: _effectiveOwnerMode,
              ),
              childCount: _matchingVideos.length,
            ),
          ),
        ),
      if (_matchingMovies.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  'From Movies DB',
                  count: _matchingMovies.length,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 198,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _matchingMovies.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (_, idx) =>
                        _buildMovieCard(_matchingMovies[idx]),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildLibrarySlivers(List<TelegramVideoItem> gridVideos) {
    if (_loadingFeed) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _buildSectionHeader('Stream Library'),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildShimmerGrid(count: 6),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ];
    }

    return [
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
              'Stream Library',
              count: gridVideos.length,
            ),
          ),
        ),
        if (gridVideos.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildEmptyState(),
            ),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.86,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, idx) => _buildMovieGridCard(
                  gridVideos[idx],
                  canDelete: _effectiveOwnerMode,
                ),
                childCount: gridVideos.length,
              ),
            ),
          ),
          if (_loadingMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: _buildShimmerGrid(count: 2),
              ),
            ),
        ],
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 28)),
    ];
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
        appBar: _buildAppBar(),
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
                if (_resolvingCode || _refreshingFeed)
                  const SliverToBoxAdapter(
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: _kAccent,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                SliverToBoxAdapter(
                  child: _buildSearchAndCodeBar(isSearchingText),
                ),
                if (isSearchingText)
                  ..._buildSearchResultSlivers()
                else
                  ..._buildLibrarySlivers(gridVideos),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniStepRow extends StatelessWidget {
  const _MiniStepRow({required this.step, required this.text});

  final String step;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: _TelegramVideosPageState._kAccent.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: const TextStyle(
                color: _TelegramVideosPageState._kAccent,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: _TelegramVideosPageState._kTextSecondary,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

/// Bottom sheet displaying the last watched frame and progress before resuming playback.
class ContinueWatchResumeSheet extends StatelessWidget {
  const ContinueWatchResumeSheet({
    super.key,
    required this.title,
    required this.quality,
    required this.clock,
    required this.fraction,
    required this.hasLastFrame,
    required this.hasAnyFrame,
    required this.previewChild,
    required this.onClose,
    required this.onStartOver,
    required this.onResume,
    this.totalClock,
    this.remainingLabel,
  });

  static const Color _kSheetBg = Color(0xFF121622);
  static const Color _kSurfaceLight = Color(0xFF171C2A);
  static const Color _kInputBg = Color(0xFF0D1018);
  static const Color _kCardBorder = Color(0xFF1E2434);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFF5F7FA);
  static const Color _kTextSecondary = Color(0xFF8E97AB);

  final String title;
  final String quality;
  final String clock;
  final String? totalClock;
  final String? remainingLabel;
  final double fraction;
  final bool hasLastFrame;
  final bool hasAnyFrame;
  final Widget previewChild;
  final VoidCallback onClose;
  final VoidCallback onStartOver;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _kSheetBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(top: BorderSide(color: _kCardBorder, width: 1.2)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _kAccent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _kAccent.withValues(alpha: 0.32),
                      ),
                    ),
                    child: const Icon(
                      Icons.history_rounded,
                      color: _kAccent,
                      size: 17,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Continue Watching?',
                      style: TextStyle(
                        color: _kTextPrimary,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: onClose,
                    icon: const Icon(
                      Icons.close_rounded,
                      color: _kTextSecondary,
                      size: 20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: _kInputBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: hasLastFrame
                        ? _kAccent.withValues(alpha: 0.42)
                        : _kCardBorder,
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        previewChild,
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.42),
                                  Colors.black.withValues(alpha: 0.05),
                                  Colors.black.withValues(alpha: 0.88),
                                ],
                                stops: const [0.0, 0.45, 1.0],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 10,
                          left: 10,
                          right: 10,
                          child: Row(
                            children: [
                              if (hasAnyFrame)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(
                                      alpha: 0.65,
                                    ),
                                    borderRadius: BorderRadius.circular(99),
                                    border: Border.all(
                                      color: hasLastFrame
                                          ? _kAccent.withValues(alpha: 0.55)
                                          : Colors.white24,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: hasLastFrame
                                              ? _kAccent
                                              : _kTextSecondary,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        hasLastFrame
                                            ? 'Last frame'
                                            : 'Scene preview',
                                        style: const TextStyle(
                                          color: _kTextPrimary,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(
                                    alpha: 0.65,
                                  ),
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Text(
                                  quality,
                                  style: const TextStyle(
                                    color: _kTextPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                            Positioned(
                              left: 12,
                              right: 12,
                              bottom: 10,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Stopped at $clock',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: _kAccent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      if (totalClock != null) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          '$totalClock • ${(fraction * 100).round()}%',
                                          maxLines: 1,
                                          style: const TextStyle(
                                            color: _kTextPrimary,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      value: fraction,
                                      minHeight: 4,
                                      backgroundColor: Colors.white24,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                        _kAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  remainingLabel != null
                      ? '$remainingLabel • Stopped at $clock'
                      : 'Ready to continue from $clock',
                  style: const TextStyle(
                    color: _kTextSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kTextPrimary,
                          backgroundColor: _kSurfaceLight.withValues(
                            alpha: 0.5,
                          ),
                          side: const BorderSide(color: _kCardBorder),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: onStartOver,
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Start Over',
                            maxLines: 1,
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAccent,
                          foregroundColor: const Color(0xFF04140F),
                          elevation: 0,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: onResume,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.play_arrow_rounded, size: 20),
                              const SizedBox(width: 6),
                              Text(
                                'Resume ($clock)',
                                maxLines: 1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
