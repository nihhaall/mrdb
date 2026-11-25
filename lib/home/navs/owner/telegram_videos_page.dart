import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/main.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/widgets/mkv_stream_player_page.dart';
import 'package:url_launcher/url_launcher.dart';

class TelegramVideosPage extends StatefulWidget {
  const TelegramVideosPage({super.key});

  @override
  State<TelegramVideosPage> createState() => _TelegramVideosPageState();
}

class _TelegramVideosPageState extends State<TelegramVideosPage> {
  static const Color _kBgColor = Color(0xFF0D0D14);
  static const Color _kCardBg = Color(0xFF151821);
  static const Color _kCardBorder = Color(0xFF202534);
  static const Color _kAccent = Color(0xFF00E5A0);

  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  bool _loadingFeed = true;
  bool _resolvingCode = false;
  bool _searching = false;
  String? _feedError;

  List<TelegramVideoItem> _botVideos = [];
  List<TelegramVideoItem> _matchingVideos = [];
  List<Map<String, dynamic>> _matchingMovies = [];
  List<TelegramVideoItem> _savedLinks = [];

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _codeController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loadingFeed = true;
      _feedError = null;
    });
    final results = await Future.wait([
      TelegramStreamService.instance.fetchBotVideos(),
      TelegramStreamService.instance.getSavedManualVideos(),
    ]);
    final feed = results[0] as TelegramVideosResult;
    final saved = results[1] as List<TelegramVideoItem>;
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
      _savedLinks = uniqueSaved;
      _loadingFeed = false;
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

  void _openVideo(TelegramVideoItem item) {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MkvStreamPlayerPage(
          title: item.title,
          streamUrl: item.streamUrl,
          fallbackWebUrl: item.watchUrl,
          formatLabel: item.formatBadge,
        ),
      ),
    );
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

  Widget _buildVideoTile(TelegramVideoItem item, {bool canDelete = false}) {
    final title = _friendlyTitle(item);
    final sizeText = item.fileSize > 0
        ? TelegramStreamService.formatBytes(item.fileSize)
        : 'Ready to play';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kCardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openVideo(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: _kAccent,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sizeText,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (canDelete)
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white38,
                    size: 19,
                  ),
                  onPressed: () async {
                    await TelegramStreamService.instance.removeManualVideo(
                      item.streamUrl,
                    );
                    await _loadInitial();
                  },
                )
              else
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white30,
                  size: 22,
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
            color: _kCardBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.movie_outlined, color: Colors.white30, size: 28),
              SizedBox(height: 4),
              Text(
                'No Poster',
                style: TextStyle(color: Colors.white38, fontSize: 10),
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
            ),
          ),
        );
      },
      child: SizedBox(
        width: 106,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
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
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (year.isNotEmpty)
              Text(
                year,
                style: const TextStyle(color: Colors.white54, fontSize: 10.5),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    String title, {
    int? count,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (count != null && count > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
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

    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Stream',
          style: TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _openBotInTelegram,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kAccent.withValues(alpha: 0.35)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.send_rounded, color: _kAccent, size: 14),
                    SizedBox(width: 5),
                    Text(
                      'Open Bot',
                      style: TextStyle(
                        color: _kAccent,
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
      ),
      body: RefreshIndicator(
        color: _kAccent,
        onRefresh: _loadInitial,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
          children: [
            // 1. Unique Stream Code Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _kAccent.withValues(alpha: 0.12),
                    _kCardBg,
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _kAccent.withValues(alpha: 0.28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _kAccent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(
                          Icons.vpn_key_rounded,
                          color: _kAccent,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 9),
                      const Expanded(
                        child: Text(
                          'Play with Stream Code',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: _pasteFromClipboard,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.content_paste_rounded,
                                color: _kAccent,
                                size: 13,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Paste',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 5, 4),
                    decoration: BoxDecoration(
                      color: _kBgColor,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: _kCardBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                            textCapitalization: TextCapitalization.characters,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _playByCode(),
                            decoration: const InputDecoration(
                              hintText: 'Paste MRDB code here...',
                              hintStyle: TextStyle(
                                color: Colors.white38,
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0,
                              ),
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kAccent,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _resolvingCode ? null : _playByCode,
                          icon: _resolvingCode
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Icon(Icons.play_arrow_rounded, size: 18),
                          label: Text(
                            _resolvingCode ? 'Loading' : 'Play',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 2. Unified Search (Movies DB + Bot Videos)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(
                color: _kCardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _kCardBorder),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search movies or video files...',
                  hintStyle: const TextStyle(color: Colors.white38),
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
                            color: Colors.white54,
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
            const SizedBox(height: 20),

            // 3. Search Results OR Bot Videos List
            if (isSearchingText) ...[
              if (_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: CircularProgressIndicator(color: _kAccent),
                  ),
                )
              else ...[
                _buildSectionHeader(
                  'Matching Videos',
                  count: _matchingVideos.length,
                ),
                const SizedBox(height: 10),
                if (_matchingVideos.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(14),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: _kCardBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _kCardBorder),
                    ),
                    child: const Text(
                      'No matching bot video files found.',
                      style: TextStyle(color: Colors.white54, fontSize: 12.5),
                    ),
                  )
                else
                  for (final v in _matchingVideos) _buildVideoTile(v),

                if (_matchingMovies.isNotEmpty) ...[
                  const SizedBox(height: 14),
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
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (_, idx) =>
                          _buildMovieCard(_matchingMovies[idx]),
                    ),
                  ),
                ],
              ],
            ] else ...[
              _buildSectionHeader(
                'Videos',
                count: _botVideos.length,
                trailing: IconButton(
                  tooltip: 'Refresh',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: Colors.white54,
                    size: 20,
                  ),
                  onPressed: _loadInitial,
                ),
              ),
              const SizedBox(height: 10),
              if (_loadingFeed)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: CircularProgressIndicator(color: _kAccent),
                  ),
                )
              else if (_feedError != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _kCardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.orangeAccent.withValues(alpha: 0.35),
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
                          _feedError!,
                          style: const TextStyle(
                            color: Colors.white70,
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
                )
              else if (_botVideos.isEmpty)
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: _kCardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kCardBorder),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.video_library_outlined,
                        color: Colors.white38,
                        size: 32,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'No videos yet. Send an MKV or MP4 to the Telegram bot to stream it here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kAccent,
                          side: BorderSide(
                            color: _kAccent.withValues(alpha: 0.4),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _openBotInTelegram,
                        icon: const Icon(Icons.send_rounded, size: 15),
                        label: const Text('Open Telegram Bot'),
                      ),
                    ],
                  ),
                )
              else
                for (final v in _botVideos) _buildVideoTile(v),

              if (_savedLinks.isNotEmpty) ...[
                const SizedBox(height: 18),
                _buildSectionHeader(
                  'Recent Streams',
                  count: _savedLinks.length,
                ),
                const SizedBox(height: 10),
                for (final v in _savedLinks)
                  _buildVideoTile(v, canDelete: true),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
