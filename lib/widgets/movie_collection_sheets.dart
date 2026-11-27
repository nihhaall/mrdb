import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/services/telegram_stream_service.dart';

class TmdbMovieSelection {
  final int id;
  final String title;
  final String? posterPath;
  final String? releaseYear;
  final bool unlink;

  const TmdbMovieSelection({
    required this.id,
    required this.title,
    this.posterPath,
    this.releaseYear,
    this.unlink = false,
  });

  const TmdbMovieSelection.unlink()
      : id = 0,
        title = '',
        posterPath = null,
        releaseYear = null,
        unlink = true;
}

const Color _kBgColor = Color(0xFF000000);
const Color _kCardBg = Color(0xFF10131C);
const Color _kSurfaceLight = Color(0xFF171C2A);
const Color _kInputBg = Color(0xFF0D1018);
const Color _kCardBorder = Color(0xFF1E2434);
const Color _kAccent = Color(0xFF00E5A0);
const Color _kAccentCyan = Color(0xFF00B0FF);
const Color _kDanger = Color(0xFFFF6B6B);
const Color _kTextPrimary = Color(0xFFF5F7FA);
const Color _kTextSecondary = Color(0xFF8E97AB);

/// Opens an owner-only full-screen TMDB movie search page so a stream file can
/// be linked to an official TMDB movie entry ("Add to Collection").
Future<TmdbMovieSelection?> showTmdbMoviePickerSheet(
  BuildContext context, {
  String? initialQuery,
  String? fileLabel,
  int? currentTmdbId,
  String? currentTmdbTitle,
  TelegramVideoItem? videoItem,
  bool isOwner = false,
}) {
  return Navigator.push<TmdbMovieSelection>(
    context,
    MaterialPageRoute(
      builder: (_) => TmdbMoviePickerPage(
        initialQuery: initialQuery ?? '',
        fileLabel: fileLabel,
        currentTmdbId: currentTmdbId,
        currentTmdbTitle: currentTmdbTitle,
        videoItem: videoItem,
        isOwner: isOwner,
      ),
    ),
  );
}

/// Full-screen page for searching TMDB movies and linking one to a stream file.
class TmdbMoviePickerPage extends StatefulWidget {
  const TmdbMoviePickerPage({
    super.key,
    required this.initialQuery,
    this.fileLabel,
    this.currentTmdbId,
    this.currentTmdbTitle,
    this.videoItem,
    this.isOwner = false,
  });

  final String initialQuery;
  final String? fileLabel;
  final int? currentTmdbId;
  final String? currentTmdbTitle;
  final TelegramVideoItem? videoItem;
  final bool isOwner;

  @override
  State<TmdbMoviePickerPage> createState() => _TmdbMoviePickerPageState();
}

class _TmdbMoviePickerPageState extends State<TmdbMoviePickerPage> {
  static const int _pageSize = 10;

  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;
  bool _loading = false;
  bool _loadingMore = false;
  bool _aiPicking = false;
  bool _hasSearched = false;
  bool _tmdbHasMore = false;
  int _tmdbPage = 1;
  List<Map<String, dynamic>> _results = [];
  List<Map<String, dynamic>> _pendingBuffer = [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController = TextEditingController(
      text: TelegramStreamService.cleanSearchTitle(widget.initialQuery),
    );
    if (_searchController.text.trim().isNotEmpty) {
      _runSearch(_searchController.text.trim());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  void _onQueryChanged(String raw) {
    _debounce?.cancel();
    final q = raw.trim();
    if (q.isEmpty) {
      setState(() {
        _loading = false;
        _loadingMore = false;
        _hasSearched = false;
        _tmdbHasMore = false;
        _tmdbPage = 1;
        _results = [];
        _pendingBuffer = [];
      });
      return;
    }
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(q));
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _tmdbPage = 1;
      _tmdbHasMore = false;
      _pendingBuffer = [];
    });
    final res = await TelegramStreamService.instance.searchTmdbMoviesPage(
      query,
      page: 1,
    );
    if (!mounted) return;
    final initial = res.movies.take(_pageSize).toList();
    final overflow = res.movies.skip(_pageSize).toList();
    setState(() {
      _results = initial;
      _pendingBuffer = overflow;
      _tmdbHasMore = res.hasMore;
      _loading = false;
      _hasSearched = true;
    });
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore) return;
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    if (_pendingBuffer.isEmpty && !_tmdbHasMore) return;

    setState(() => _loadingMore = true);
    if (_pendingBuffer.length < _pageSize && _tmdbHasMore) {
      final nextPage = _tmdbPage + 1;
      final res = await TelegramStreamService.instance.searchTmdbMoviesPage(
        query,
        page: nextPage,
      );
      if (!mounted) return;
      _tmdbPage = nextPage;
      _tmdbHasMore = res.hasMore;
      final existingIds = _results.map((e) => e['id']).toSet()
        ..addAll(_pendingBuffer.map((e) => e['id']));
      for (final m in res.movies) {
        if (existingIds.add(m['id'])) {
          _pendingBuffer.add(m);
        }
      }
    }
    if (!mounted) return;
    final nextChunk = _pendingBuffer.take(_pageSize).toList();
    _pendingBuffer = _pendingBuffer.skip(_pageSize).toList();
    setState(() {
      _results = [..._results, ...nextChunk];
      _loadingMore = false;
    });
  }

  Future<void> _runAiPick() async {
    setState(() => _aiPicking = true);
    final picked = await _resolveAndConfirmAiTmdbMatch(
      context,
      rawFileName: widget.videoItem?.fileName ??
          widget.fileLabel ??
          _searchController.text.trim(),
      existingTitle: _searchController.text.trim().isNotEmpty
          ? _searchController.text.trim()
          : widget.fileLabel,
      explicitYear: widget.videoItem?.year,
      videoItem: widget.videoItem,
    );
    if (!mounted) return;
    setState(() => _aiPicking = false);
    if (picked != null) {
      Navigator.pop(context, picked.selection);
    }
  }

  @override
  Widget build(BuildContext context) {
    final queryText = _searchController.text.trim();
    final hasFileLabel =
        widget.fileLabel != null && widget.fileLabel!.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: _kTextPrimary),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add to Collection',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'Search TMDB movie to link & save',
              style: TextStyle(
                color: _kTextSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          if (widget.isOwner)
            Padding(
              padding: EdgeInsets.only(
                right: widget.currentTmdbId != null ? 4 : 12,
              ),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: _kAccentCyan,
                  backgroundColor: _kAccentCyan.withValues(alpha: 0.14),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _aiPicking ? null : _runAiPick,
                icon: _aiPicking
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _kAccentCyan,
                        ),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 14),
                label: const Text(
                  'AI Pick',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          if (widget.currentTmdbId != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: _kDanger,
                  backgroundColor: _kDanger.withValues(alpha: 0.14),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  Navigator.pop(context, const TmdbMovieSelection.unlink());
                },
                child: const Text(
                  'Unlink',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasFileLabel || widget.currentTmdbId != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _kCardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: widget.currentTmdbId != null
                          ? _kAccent.withValues(alpha: 0.4)
                          : _kCardBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        widget.currentTmdbId != null
                            ? Icons.check_circle_rounded
                            : Icons.movie_creation_outlined,
                        color: widget.currentTmdbId != null
                            ? _kAccent
                            : _kAccentCyan,
                        size: 17,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          widget.currentTmdbId != null
                              ? 'Currently linked: ${widget.currentTmdbTitle?.isNotEmpty == true ? widget.currentTmdbTitle! : 'Movie #${widget.currentTmdbId}'}'
                              : 'File: ${widget.fileLabel!.trim()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _kTextPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: _kInputBg,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: _kAccent.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search_rounded,
                      color: _kAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        textInputAction: TextInputAction.search,
                        onChanged: _onQueryChanged,
                        onSubmitted: (v) {
                          if (v.trim().isNotEmpty) _runSearch(v.trim());
                        },
                        decoration: const InputDecoration(
                          hintText: 'Type movie name (e.g. Inception)...',
                          hintStyle: TextStyle(
                            color: _kTextSecondary,
                            fontSize: 13.5,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 11),
                        ),
                      ),
                    ),
                    if (queryText.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _kTextSecondary,
                          size: 18,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              color: _kAccent,
                              strokeWidth: 2.5,
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Searching TMDB movies...',
                              style: TextStyle(
                                color: _kTextSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _results.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _hasSearched
                                        ? Icons.search_off_rounded
                                        : Icons.local_movies_rounded,
                                    color: _kTextSecondary.withValues(
                                      alpha: 0.7,
                                    ),
                                    size: 38,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _hasSearched && queryText.isNotEmpty
                                        ? 'No TMDB movies found for "$queryText"'
                                        : 'Search a movie title above and tap it to save to the collection.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: _kTextPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  const Text(
                                    'Tip: Short movie names without tags match best.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _kTextSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: _scrollController,
                            itemCount: _results.length + (_loadingMore ? 1 : 0),
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 9),
                            itemBuilder: (_, idx) {
                              if (idx >= _results.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 14),
                                  child: Center(
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: _kAccent,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              final m = _results[idx];
                              final id = (m['id'] as num?)?.toInt();
                              if (id == null) return const SizedBox.shrink();
                              final title =
                                  (m['title'] ?? m['original_title'] ?? 'Movie')
                                      .toString();
                              final date = (m['release_date'] ?? '').toString();
                              final year =
                                  date.length >= 4 ? date.substring(0, 4) : '';
                              final poster = m['poster_path']?.toString();
                              final rating =
                                  (m['vote_average'] as num?)?.toDouble() ?? 0;
                              final overview =
                                  (m['overview'] ?? '').toString().trim();
                              final isCurrent = widget.currentTmdbId == id;

                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    Navigator.pop(
                                      context,
                                      TmdbMovieSelection(
                                        id: id,
                                        title: title,
                                        posterPath: poster,
                                        releaseYear:
                                            year.isNotEmpty ? year : null,
                                      ),
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isCurrent
                                          ? _kAccent.withValues(alpha: 0.12)
                                          : _kCardBg,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isCurrent
                                            ? _kAccent.withValues(alpha: 0.6)
                                            : _kCardBorder,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: SizedBox(
                                            width: 54,
                                            height: 80,
                                            child: poster != null &&
                                                    poster.isNotEmpty
                                                ? CachedNetworkImage(
                                                    imageUrl:
                                                        '${AppConstants.baseImageUrl}$poster',
                                                    fit: BoxFit.cover,
                                                    errorWidget: (_, _, _) =>
                                                        Container(
                                                      color: _kSurfaceLight,
                                                      child: const Icon(
                                                        Icons.movie_rounded,
                                                        color: _kTextSecondary,
                                                        size: 22,
                                                      ),
                                                    ),
                                                  )
                                                : Container(
                                                    color: _kSurfaceLight,
                                                    child: const Icon(
                                                      Icons.movie_rounded,
                                                      color: _kTextSecondary,
                                                      size: 22,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: _kTextPrimary,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Row(
                                                children: [
                                                  if (year.isNotEmpty) ...[
                                                    Text(
                                                      year,
                                                      style: const TextStyle(
                                                        color: _kTextSecondary,
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                  ],
                                                  if (rating > 0) ...[
                                                    const Icon(
                                                      Icons.star_rounded,
                                                      color: Color(0xFFF5C451),
                                                      size: 13.5,
                                                    ),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      rating.toStringAsFixed(1),
                                                      style: const TextStyle(
                                                        color: _kTextSecondary,
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              if (overview.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  overview,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: _kTextSecondary,
                                                    fontSize: 11,
                                                    height: 1.25,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 11,
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isCurrent
                                                ? _kAccent
                                                : _kAccent.withValues(
                                                    alpha: 0.14,
                                                  ),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            isCurrent ? 'Linked' : 'Select',
                                            style: TextStyle(
                                              color: isCurrent
                                                  ? const Color(0xFF04140F)
                                                  : _kAccent,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the owner-only full-screen editor page for renaming a streamed movie,
/// editing metadata (year, quality, language, notes), linking/unlinking a TMDB
/// movie, and removing unwanted audio tracks from multi-audio files.
Future<TelegramVideoItem?> showEditMovieMetadataSheet(
  BuildContext context, {
  required TelegramVideoItem item,
  Future<void> Function()? onRequestDelete,
}) {
  return Navigator.push<TelegramVideoItem>(
    context,
    MaterialPageRoute(
      builder: (_) => EditMovieMetadataPage(
        item: item,
        onRequestDelete: onRequestDelete,
      ),
    ),
  );
}

/// Full-screen owner editor page for movie file metadata and multi-audio tracks.
class EditMovieMetadataPage extends StatefulWidget {
  const EditMovieMetadataPage({
    super.key,
    required this.item,
    this.onRequestDelete,
  });

  final TelegramVideoItem item;
  final Future<void> Function()? onRequestDelete;

  @override
  State<EditMovieMetadataPage> createState() => _EditMovieMetadataPageState();
}

class _EditMovieMetadataPageState extends State<EditMovieMetadataPage> {
  static const List<String> _qualityPresets = [
    '4K',
    '1080p',
    '720p',
    '480p',
    'HDRip',
  ];

  late final TextEditingController _titleController;
  late final TextEditingController _yearController;
  late final TextEditingController _qualityController;
  late final TextEditingController _languageController;
  late final TextEditingController _overviewController;

  int? _tmdbId;
  String? _tmdbTitle;
  String? _tmdbPoster;
  String? _tmdbYear;
  bool _clearTmdb = false;

  bool _loadingTracks = true;
  bool _saving = false;
  bool _smartCorrecting = false;
  bool _aiPicking = false;
  late bool _hiddenForUsers;
  String? _tracksError;
  String? _saveError;
  List<VideoAudioTrackInfo> _audioTracks = [];
  late Set<int> _disabledAudioIndices;

  @override
  void initState() {
    super.initState();
    final initialName = widget.item.metadataEdited &&
            widget.item.title.trim().isNotEmpty
        ? widget.item.title.trim()
        : widget.item.fileName;
    _titleController = TextEditingController(text: initialName);
    _yearController = TextEditingController(
      text: widget.item.year != null ? '${widget.item.year}' : '',
    );
    _qualityController = TextEditingController(text: widget.item.quality ?? '');
    _languageController = TextEditingController(
      text: widget.item.language ?? '',
    );
    _overviewController = TextEditingController(
      text: widget.item.overview ?? '',
    );
    _tmdbId = widget.item.tmdbId;
    _tmdbTitle = widget.item.tmdbTitle;
    _tmdbPoster = widget.item.tmdbPoster;
    _tmdbYear = widget.item.tmdbYear;
    _hiddenForUsers = widget.item.hiddenForUsers;
    _audioTracks = List<VideoAudioTrackInfo>.from(widget.item.audioTracks);
    _disabledAudioIndices = widget.item.disabledAudioIndices.toSet();
    _inspectTracks();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _yearController.dispose();
    _qualityController.dispose();
    _languageController.dispose();
    _overviewController.dispose();
    super.dispose();
  }

  Future<void> _inspectTracks({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loadingTracks = true;
      _tracksError = null;
    });
    final res = await TelegramStreamService.instance.fetchBotVideoTracks(
      widget.item,
      refresh: refresh,
    );
    if (!mounted) return;
    setState(() {
      _loadingTracks = false;
      if (res.tracks.isNotEmpty) {
        _audioTracks = res.tracks;
      }
      if (res.ok) {
        _disabledAudioIndices = res.disabledAudioIndices.toSet();
      } else if (_audioTracks.isEmpty) {
        _tracksError = res.errorMessage;
      }
    });
  }

  void _toggleAudioTrack(int index, bool keepEnabled) {
    final next = Set<int>.from(_disabledAudioIndices);
    if (keepEnabled) {
      next.remove(index);
    } else {
      final enabledRemaining = _audioTracks
          .where((t) => t.index != index && !next.contains(t.index))
          .length;
      if (_audioTracks.isNotEmpty && enabledRemaining == 0) {
        setState(() {
          _saveError = 'Keep at least 1 active audio track so playback has sound.';
        });
        return;
      }
      next.add(index);
    }
    setState(() {
      _saveError = null;
      _disabledAudioIndices = next;
    });
  }

  Future<void> _renameAudioTrack(VideoAudioTrackInfo track) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameAudioTrackDialog(
        trackNumber: track.index + 1,
        initialTitle: track.title,
      ),
    );
    if (newName == null || !mounted) return;
    setState(() {
      _audioTracks = _audioTracks
          .map((t) => t.index == track.index ? t.copyWith(title: newName) : t)
          .toList();
    });
  }

  Future<void> _runAiSmartCorrect() async {
    if (_smartCorrecting) return;
    setState(() {
      _smartCorrecting = true;
      _saveError = null;
    });
    final suggestion = await TelegramStreamService.instance.smartCorrectMetadata(
      widget.item.fileName,
      existingTitle: _titleController.text,
      videoItem: widget.item,
    );
    if (!mounted) return;
    setState(() {
      _smartCorrecting = false;
      if (suggestion.title.isNotEmpty) {
        _titleController.text = suggestion.title;
      }
      if (suggestion.year != null) {
        _yearController.text = '${suggestion.year}';
      }
      if (suggestion.quality != null && suggestion.quality!.isNotEmpty) {
        _qualityController.text = suggestion.quality!;
      }
      if (suggestion.language != null && suggestion.language!.isNotEmpty) {
        _languageController.text = suggestion.language!;
      }
      if (suggestion.overview != null && _overviewController.text.trim().isEmpty) {
        _overviewController.text = suggestion.overview!;
      }
      if (!_clearTmdb && _tmdbId == null && suggestion.tmdbId != null) {
        _tmdbId = suggestion.tmdbId;
        _tmdbTitle = suggestion.tmdbTitle;
        _tmdbPoster = suggestion.tmdbPoster;
        _tmdbYear = suggestion.tmdbYear;
      }
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: _kCardBg,
          content: Text(
            suggestion.usedAi && suggestion.matchedTmdb
                ? '${suggestion.aiProvider} + TMDB: ${suggestion.title}'
                : suggestion.usedAi
                    ? '${suggestion.aiProvider}: ${suggestion.title}'
                    : suggestion.matchedTmdb
                        ? 'Matched TMDB: ${suggestion.title}'
                        : 'Cleaned locally from filename',
            style: const TextStyle(color: _kAccent, fontWeight: FontWeight.w700),
          ),
        ),
      );
  }

  Future<void> _runAiPickMovie() async {
    if (_aiPicking) return;
    setState(() {
      _aiPicking = true;
      _saveError = null;
    });
    final picked = await _resolveAndConfirmAiTmdbMatch(
      context,
      rawFileName: widget.item.fileName,
      existingTitle: _titleController.text,
      explicitYear: int.tryParse(_yearController.text.trim()),
      explicitLanguage: _languageController.text.trim(),
      videoItem: widget.item,
    );
    if (!mounted) return;
    setState(() => _aiPicking = false);
    if (picked == null) return;

    setState(() {
      _clearTmdb = false;
      _tmdbId = picked.selection.id;
      _tmdbTitle = picked.selection.title;
      _tmdbPoster = picked.selection.posterPath;
      _tmdbYear = picked.selection.releaseYear;
      if (_yearController.text.trim().isEmpty &&
          picked.selection.releaseYear != null) {
        _yearController.text = picked.selection.releaseYear!;
      }
      if (_overviewController.text.trim().isEmpty &&
          picked.overview.isNotEmpty) {
        _overviewController.text = picked.overview;
      }
    });
  }

  Future<void> _pickTmdbMovie() async {
    final cleanMovieName = TelegramStreamService.analyzeFileNameLocally(
      widget.item.fileName,
      existingTitle: _titleController.text.trim().isNotEmpty
          ? _titleController.text.trim()
          : null,
    ).searchQuery;
    final chosen = await showTmdbMoviePickerSheet(
      context,
      initialQuery: cleanMovieName.isNotEmpty
          ? cleanMovieName
          : TelegramStreamService.cleanSearchTitle(widget.item.fileName),
      fileLabel: widget.item.fileName,
      currentTmdbId: _clearTmdb ? null : _tmdbId,
      currentTmdbTitle: _clearTmdb ? null : _tmdbTitle,
      videoItem: widget.item,
      isOwner: true,
    );
    if (chosen == null || !mounted) return;
    if (chosen.unlink) {
      setState(() {
        _clearTmdb = true;
        _tmdbId = null;
        _tmdbTitle = null;
        _tmdbPoster = null;
        _tmdbYear = null;
      });
      return;
    }
    setState(() {
      _clearTmdb = false;
      _tmdbId = chosen.id;
      _tmdbTitle = chosen.title;
      _tmdbPoster = chosen.posterPath;
      _tmdbYear = chosen.releaseYear;
      if (_titleController.text.trim() == widget.item.fileName.trim() ||
          _titleController.text.trim().isEmpty) {
        _titleController.text = chosen.title;
      }
      if (_yearController.text.trim().isEmpty && chosen.releaseYear != null) {
        _yearController.text = chosen.releaseYear!;
      }
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _saveError = 'Movie name cannot be empty.');
      return;
    }
    final rawYear = _yearController.text.trim();
    int? parsedYear;
    if (rawYear.isNotEmpty) {
      parsedYear = int.tryParse(rawYear);
      if (parsedYear == null || parsedYear < 1900 || parsedYear > 2100) {
        setState(() => _saveError = 'Enter a valid 4-digit year (e.g. 2024).');
        return;
      }
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });

    final updated = await TelegramStreamService.instance.updateBotVideoMetadata(
      widget.item,
      title: title,
      year: parsedYear,
      clearYear: rawYear.isEmpty,
      quality: _qualityController.text.trim(),
      language: _languageController.text.trim(),
      overview: _overviewController.text.trim(),
      tmdbId: _clearTmdb ? null : _tmdbId,
      clearTmdb: _clearTmdb,
      tmdbTitle: _clearTmdb ? null : _tmdbTitle,
      tmdbPoster: _clearTmdb ? null : _tmdbPoster,
      tmdbYear: _clearTmdb ? null : _tmdbYear,
      hiddenForUsers: _hiddenForUsers,
      disabledAudioIndices: _disabledAudioIndices.toList()..sort(),
      audioTracks: _audioTracks.isNotEmpty ? _audioTracks : null,
    );

    if (!mounted) return;
    if (updated == null) {
      setState(() {
        _saving = false;
        _saveError = 'Could not save to server. Check bot connection.';
      });
      return;
    }
    Navigator.pop(context, updated);
  }

  Widget _buildInputBox({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboardType,
    int maxLines = 1,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: _kTextSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (suffix != null) suffix,
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: _kInputBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kCardBorder),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            maxLines: maxLines,
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: _kTextSecondary, fontSize: 13),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasLinkedMovie = !_clearTmdb && _tmdbId != null;

    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: _kTextPrimary),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit Metadata & Audio',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'Saved changes show for all MRDb users',
              style: TextStyle(
                color: _kTextSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          if (widget.onRequestDelete != null)
            IconButton(
              tooltip: 'Remove from Stream',
              onPressed: _saving
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await widget.onRequestDelete?.call();
                    },
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: _kDanger,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _buildInputBox(
            controller: _titleController,
            label: 'Movie / File Name',
            hint: 'Enter clean movie or file name...',
            suffix: GestureDetector(
              onTap: _smartCorrecting ? null : _runAiSmartCorrect,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _kAccent.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_smartCorrecting)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _kAccent,
                        ),
                      )
                    else
                      const Icon(
                        Icons.auto_awesome_rounded,
                        color: _kAccent,
                        size: 13.5,
                      ),
                    const SizedBox(width: 5),
                    const Text(
                      'AI Correct',
                      style: TextStyle(
                        color: _kAccent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _buildInputBox(
                  controller: _yearController,
                  label: 'Year',
                  hint: '2024',
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: _buildInputBox(
                  controller: _qualityController,
                  label: 'Quality Tag',
                  hint: '1080p, 4K, HDRip...',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final q in _qualityPresets)
                GestureDetector(
                  onTap: () {
                    setState(() => _qualityController.text = q);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5.5,
                    ),
                    decoration: BoxDecoration(
                      color: _qualityController.text.trim().toLowerCase() ==
                              q.toLowerCase()
                          ? _kAccent.withValues(alpha: 0.18)
                          : _kSurfaceLight,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: _qualityController.text.trim().toLowerCase() ==
                                q.toLowerCase()
                            ? _kAccent.withValues(alpha: 0.55)
                            : _kCardBorder,
                      ),
                    ),
                    child: Text(
                      q,
                      style: TextStyle(
                        color: _qualityController.text.trim().toLowerCase() ==
                                q.toLowerCase()
                            ? _kAccent
                            : _kTextSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _buildInputBox(
            controller: _languageController,
            label: 'Audio Languages / Edition',
            hint: 'e.g. Malayalam • Tamil • Dual Audio',
          ),
          const SizedBox(height: 14),
          _buildInputBox(
            controller: _overviewController,
            label: 'Notes (Optional)',
            hint: 'Extra info visible on details...',
            maxLines: 2,
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: _hiddenForUsers
                    ? const Color(0xFFF5C451).withValues(alpha: 0.45)
                    : _kCardBorder,
              ),
            ),
            child: SwitchListTile(
              value: _hiddenForUsers,
              onChanged: (v) => setState(() => _hiddenForUsers = v),
              activeThumbColor: const Color(0xFFF5C451),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 13,
                vertical: 2,
              ),
              title: const Text(
                'Hide from Users (Owner Only)',
                style: TextStyle(
                  color: _kTextPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: const Text(
                'Only owners can see and stream this file',
                style: TextStyle(color: _kTextSecondary, fontSize: 11.5),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // TMDB Movie Collection Link card
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: hasLinkedMovie
                    ? _kAccentCyan.withValues(alpha: 0.42)
                    : _kCardBorder,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 62,
                    child: hasLinkedMovie &&
                            _tmdbPoster != null &&
                            _tmdbPoster!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl:
                                '${AppConstants.baseImageUrl}$_tmdbPoster',
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => Container(
                              color: _kSurfaceLight,
                              child: const Icon(
                                Icons.movie_rounded,
                                color: _kAccentCyan,
                                size: 20,
                              ),
                            ),
                          )
                        : Container(
                            color: _kSurfaceLight,
                            child: Icon(
                              Icons.movie_filter_rounded,
                              color: hasLinkedMovie
                                  ? _kAccentCyan
                                  : _kTextSecondary,
                              size: 20,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasLinkedMovie
                            ? (_tmdbTitle?.isNotEmpty == true
                                ? _tmdbTitle!
                                : 'Linked Movie #$_tmdbId')
                            : 'Movie Collection Link',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        hasLinkedMovie
                            ? '${_tmdbYear != null ? '${_tmdbYear!} • ' : ''}Shows on Movie Preview page'
                            : 'Link to a TMDB movie page',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _kTextSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (hasLinkedMovie)
                  IconButton(
                    tooltip: 'Unlink movie',
                    onPressed: () {
                      setState(() {
                        _clearTmdb = true;
                        _tmdbId = null;
                        _tmdbTitle = null;
                        _tmdbPoster = null;
                        _tmdbYear = null;
                      });
                    },
                    icon: const Icon(
                      Icons.link_off_rounded,
                      color: _kDanger,
                      size: 19,
                    ),
                  ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: _kAccentCyan,
                    backgroundColor: _kAccentCyan.withValues(alpha: 0.12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _aiPicking ? null : _runAiPickMovie,
                  icon: _aiPicking
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kAccentCyan,
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 14),
                  label: const Text(
                    'AI Pick',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: _kAccent,
                    backgroundColor: _kAccent.withValues(alpha: 0.14),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _pickTmdbMovie,
                  child: Text(
                    hasLinkedMovie ? 'Change' : 'Select',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Multi-Audio Track Manager
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.audiotrack_rounded,
                      color: _kAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 7),
                    const Expanded(
                      child: Text(
                        'Multi-Audio Tracks',
                        style: TextStyle(
                          color: _kTextPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _loadingTracks
                          ? null
                          : () => _inspectTracks(refresh: true),
                      icon: const Icon(
                        Icons.refresh_rounded,
                        size: 16,
                        color: _kAccent,
                      ),
                      label: const Text(
                        'Scan',
                        style: TextStyle(
                          color: _kAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const Text(
                  'Turn off unwanted audio tracks so they are hidden & skipped for all users.',
                  style: TextStyle(
                    color: _kTextSecondary,
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 10),
                if (_loadingTracks)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _kAccent,
                        ),
                      ),
                    ),
                  )
                else if (_audioTracks.isEmpty)
                  Text(
                    _tracksError ??
                        'No separate audio tracks detected yet. Tap Scan to inspect.',
                    style: const TextStyle(
                      color: _kTextSecondary,
                      fontSize: 12,
                    ),
                  )
                else
                  for (final track in _audioTracks) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 7),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: _disabledAudioIndices.contains(track.index)
                            ? _kDanger.withValues(alpha: 0.08)
                            : _kSurfaceLight.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _disabledAudioIndices.contains(track.index)
                              ? _kDanger.withValues(alpha: 0.35)
                              : _kCardBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.displayLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _disabledAudioIndices
                                            .contains(track.index)
                                        ? _kTextSecondary
                                        : _kTextPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    decoration: _disabledAudioIndices
                                            .contains(track.index)
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                Text(
                                  _disabledAudioIndices.contains(track.index)
                                      ? 'Removed from playback'
                                      : 'Active track #${track.index + 1}',
                                  style: TextStyle(
                                    color: _disabledAudioIndices
                                            .contains(track.index)
                                        ? _kDanger
                                        : _kAccent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Rename audio track',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _renameAudioTrack(track),
                            icon: const Icon(
                              Icons.edit_rounded,
                              color: _kTextSecondary,
                              size: 18,
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  _disabledAudioIndices.contains(track.index)
                                      ? _kAccent
                                      : _kDanger,
                              backgroundColor: (_disabledAudioIndices
                                          .contains(track.index)
                                      ? _kAccent
                                      : _kDanger)
                                  .withValues(alpha: 0.14),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 7,
                              ),
                              minimumSize: const Size(0, 32),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                            ),
                            onPressed: () => _toggleAudioTrack(
                              track.index,
                              _disabledAudioIndices.contains(track.index),
                            ),
                            child: Text(
                              _disabledAudioIndices.contains(track.index)
                                  ? 'Restore'
                                  : 'Remove',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: const BoxDecoration(
            color: _kBgColor,
            border: Border(top: BorderSide(color: _kCardBorder)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_saveError != null) ...[
                Text(
                  _saveError!,
                  style: const TextStyle(
                    color: _kDanger,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: const Color(0xFF04140F),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF04140F),
                        ),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(
                  _saving ? 'Saving...' : 'Save Changes',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens an owner-only full-screen page from MoviePreview so the owner can
/// search bot stream files and link/save them directly to that TMDB movie.
Future<bool?> showLinkStreamFilesSheet(
  BuildContext context, {
  required int tmdbId,
  required String movieTitle,
  String? moviePoster,
  String? movieYear,
  List<TelegramVideoItem> initialLinked = const [],
}) {
  return Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) => LinkStreamFilesPage(
        tmdbId: tmdbId,
        movieTitle: movieTitle,
        moviePoster: moviePoster,
        movieYear: movieYear,
        initialLinked: initialLinked,
      ),
    ),
  );
}

/// Full-screen owner page to select and link uploaded bot stream files to a movie.
class LinkStreamFilesPage extends StatefulWidget {
  const LinkStreamFilesPage({
    super.key,
    required this.tmdbId,
    required this.movieTitle,
    this.moviePoster,
    this.movieYear,
    this.initialLinked = const [],
  });

  final int tmdbId;
  final String movieTitle;
  final String? moviePoster;
  final String? movieYear;
  final List<TelegramVideoItem> initialLinked;

  @override
  State<LinkStreamFilesPage> createState() => _LinkStreamFilesPageState();
}

class _LinkStreamFilesPageState extends State<LinkStreamFilesPage> {
  static const int _pageSize = 10;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextOffset = 0;
  bool _saving = false;
  bool _aiPicking = false;
  String? _error;
  List<TelegramVideoItem> _files = [];
  late final Set<int> _originallyLinkedIds;
  late final Set<int> _selectedIds;
  final Map<int, TelegramVideoItem> _knownById = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _originallyLinkedIds = widget.initialLinked
        .map((e) => e.msgId)
        .whereType<int>()
        .toSet();
    _selectedIds = Set<int>.from(_originallyLinkedIds);
    for (final v in widget.initialLinked) {
      if (v.msgId != null) _knownById[v.msgId!] = v;
    }
    _fetchFiles('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMoreFiles();
    }
  }

  void _onSearchChanged(String raw) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _fetchFiles(raw.trim());
    });
  }

  Future<void> _fetchFiles(String query) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _nextOffset = 0;
      _error = null;
    });
    final res = await TelegramStreamService.instance.fetchBotVideos(
      query: query.isEmpty ? null : query,
      limit: _pageSize,
      offset: 0,
      includeHidden: true,
    );
    if (!mounted) return;
    final list = <TelegramVideoItem>[...res.videos];
    for (final linked in widget.initialLinked) {
      if (linked.msgId != null && !list.any((x) => x.msgId == linked.msgId)) {
        list.insert(0, linked);
      }
    }
    for (final v in list) {
      if (v.msgId != null) _knownById[v.msgId!] = v;
    }
    setState(() {
      _loading = false;
      _files = list;
      _nextOffset = res.rawCount > 0 ? res.rawCount : res.videos.length;
      _hasMore = res.hasMore && res.rawCount > 0;
      _error = res.videos.isEmpty ? res.errorMessage : null;
    });
  }

  Future<void> _loadMoreFiles() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final q = _searchController.text.trim();
    final res = await TelegramStreamService.instance.fetchBotVideos(
      query: q.isEmpty ? null : q,
      limit: _pageSize,
      offset: _nextOffset,
      includeHidden: true,
    );
    if (!mounted) return;
    final merged = TelegramStreamService.dedupeVideos([..._files, ...res.videos]);
    for (final v in merged) {
      if (v.msgId != null) _knownById[v.msgId!] = v;
    }
    setState(() {
      _files = merged;
      _nextOffset += res.rawCount > 0 ? res.rawCount : res.videos.length;
      _hasMore = res.hasMore && res.rawCount > 0;
      _loadingMore = false;
    });
  }

  Future<void> _runAiPickStreamFiles() async {
    if (_aiPicking) return;
    setState(() {
      _aiPicking = true;
      _error = null;
    });

    final cleanQuery = TelegramStreamService.analyzeFileNameLocally(
      widget.movieTitle,
    ).searchQuery;
    final query = cleanQuery.isNotEmpty
        ? cleanQuery
        : TelegramStreamService.cleanSearchTitle(widget.movieTitle);
    final res = await TelegramStreamService.instance.fetchBotVideos(
      query: query,
      limit: 25,
      includeHidden: true,
    );
    if (!mounted) return;
    setState(() => _aiPicking = false);

    final expectedYear = int.tryParse((widget.movieYear ?? '').trim());
    final matched = <TelegramVideoItem>[];
    for (final v in res.videos) {
      if (v.msgId == null) continue;
      final parsed = TelegramStreamService.analyzeFileNameLocally(
        v.fileName,
        existingTitle: v.title,
      );
      final fileYear = v.year ?? parsed.year;
      if (expectedYear != null && fileYear != null && (fileYear - expectedYear).abs() > 1) {
        continue;
      }
      matched.add(v);
    }

    if (matched.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: _kCardBg,
            content: Text(
              'No matching files found for "${widget.movieTitle}"'
              '${expectedYear != null ? ' ($expectedYear)' : ''}.',
              style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w700),
            ),
          ),
        );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: _kCardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        title: const Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: _kAccentCyan, size: 18),
            SizedBox(width: 8),
            Text(
              'AI Pick Matching Files',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Found ${matched.length} file(s) matching ${widget.movieTitle}'
                  '${expectedYear != null ? ' ($expectedYear)' : ''}:',
                  style: const TextStyle(color: _kTextSecondary, fontSize: 12),
                ),
                const SizedBox(height: 10),
                for (final f in matched)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: _kSurfaceLight,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _kCardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.title.trim().isNotEmpty ? f.title : f.fileName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (f.year != null) '${f.year}',
                              if ((f.quality ?? '').isNotEmpty) f.quality!,
                              if (f.fileSize > 0)
                                TelegramStreamService.formatBytes(f.fileSize),
                            ].join(' • '),
                            style: const TextStyle(
                              color: _kAccent,
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: _kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: const Color(0xFF04140F),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text(
              'Confirm & Assign',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() {
      for (final f in matched) {
        final id = f.msgId!;
        _knownById[id] = f;
        _selectedIds.add(id);
        if (!_files.any((e) => e.msgId == id)) {
          _files.insert(0, f);
        }
      }
    });
  }

  Future<void> _saveSelection() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    final toLink = _selectedIds.difference(_originallyLinkedIds);
    final toUnlink = _originallyLinkedIds.difference(_selectedIds);

    var anyFailed = false;
    for (final msgId in toLink) {
      final item = _knownById[msgId];
      if (item == null) continue;
      final res = await TelegramStreamService.instance.updateBotVideoMetadata(
        item,
        tmdbId: widget.tmdbId,
        tmdbTitle: widget.movieTitle,
        tmdbPoster: widget.moviePoster,
        tmdbYear: widget.movieYear,
      );
      if (res == null) anyFailed = true;
    }
    for (final msgId in toUnlink) {
      final item = _knownById[msgId];
      if (item == null) continue;
      final res = await TelegramStreamService.instance.updateBotVideoMetadata(
        item,
        clearTmdb: true,
      );
      if (res == null) anyFailed = true;
    }

    if (!mounted) return;
    if (anyFailed) {
      setState(() {
        _saving = false;
        _error = 'Some changes could not be saved. Retry when online.';
      });
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final hasChanges = _selectedIds.length != _originallyLinkedIds.length ||
        !_selectedIds.containsAll(_originallyLinkedIds);

    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: _kTextPrimary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Save Files to Movie',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              widget.movieTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kAccent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: _kAccentCyan,
                backgroundColor: _kAccentCyan.withValues(alpha: 0.14),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _aiPicking ? null : _runAiPickStreamFiles,
              icon: _aiPicking
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _kAccentCyan,
                      ),
                    )
                  : const Icon(Icons.auto_awesome_rounded, size: 14),
              label: const Text(
                'AI Pick',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _kCardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _kCardBorder),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 38,
                        height: 54,
                        child: widget.moviePoster != null &&
                                widget.moviePoster!.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl:
                                    '${AppConstants.baseImageUrl}${widget.moviePoster}',
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => Container(
                                  color: _kSurfaceLight,
                                  child: const Icon(
                                    Icons.movie_rounded,
                                    color: _kAccent,
                                    size: 18,
                                  ),
                                ),
                              )
                            : Container(
                                color: _kSurfaceLight,
                                child: const Icon(
                                  Icons.movie_rounded,
                                  color: _kAccent,
                                  size: 18,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.movieTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.movieYear != null ? '${widget.movieYear!} • ' : ''}Select stream files below to link here',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _kTextSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: _kInputBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _kAccent.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search_rounded,
                      color: _kAccent,
                      size: 19,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 13.5,
                        ),
                        onChanged: _onSearchChanged,
                        decoration: const InputDecoration(
                          hintText: 'Search uploaded bot stream files...',
                          hintStyle: TextStyle(color: _kTextSecondary),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          _fetchFiles('');
                        },
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _kTextSecondary,
                          size: 18,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: _kAccent,
                          strokeWidth: 2.5,
                        ),
                      )
                    : _files.isEmpty
                        ? Center(
                            child: Text(
                              _error ?? 'No matching stream files found.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: _kTextSecondary,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: _scrollController,
                            itemCount: _files.length + (_loadingMore ? 1 : 0),
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, idx) {
                              if (idx >= _files.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 14),
                                  child: Center(
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: _kAccent,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              final item = _files[idx];
                              final msgId = item.msgId;
                              if (msgId == null) return const SizedBox.shrink();
                              final selected = _selectedIds.contains(msgId);
                              final linkedElsewhere = item.tmdbId != null &&
                                  item.tmdbId != widget.tmdbId;

                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    setState(() {
                                      if (selected) {
                                        _selectedIds.remove(msgId);
                                      } else {
                                        _selectedIds.add(msgId);
                                      }
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(11),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? _kAccent.withValues(alpha: 0.12)
                                          : _kCardBg,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: selected
                                            ? _kAccent.withValues(alpha: 0.55)
                                            : _kCardBorder,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: selected
                                                ? _kAccent
                                                : _kSurfaceLight,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Icon(
                                            selected
                                                ? Icons.check_rounded
                                                : Icons.movie_rounded,
                                            color: selected
                                                ? const Color(0xFF04140F)
                                                : _kTextSecondary,
                                            size: 19,
                                          ),
                                        ),
                                        const SizedBox(width: 11),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.metadataEdited
                                                    ? item.title
                                                    : item.fileName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: _kTextPrimary,
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                [
                                                  item.formatBadge,
                                                  if (item.fileSize > 0)
                                                    TelegramStreamService
                                                        .formatBytes(
                                                      item.fileSize,
                                                    ),
                                                  if (linkedElsewhere &&
                                                      item.tmdbTitle != null)
                                                    'Linked: ${item.tmdbTitle}',
                                                ].join(' • '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: _kTextSecondary,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: const BoxDecoration(
            color: _kBgColor,
            border: Border(top: BorderSide(color: _kCardBorder)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null && _files.isNotEmpty) ...[
                Text(
                  _error!,
                  style: const TextStyle(color: _kDanger, fontSize: 12),
                ),
                const SizedBox(height: 8),
              ],
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: const Color(0xFF04140F),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: (_saving || !hasChanges) ? null : _saveSelection,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF04140F),
                        ),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(
                  _saving
                      ? 'Saving...'
                      : 'Save to Movie Collection (${_selectedIds.length})',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameAudioTrackDialog extends StatefulWidget {
  final int trackNumber;
  final String initialTitle;

  const _RenameAudioTrackDialog({
    required this.trackNumber,
    required this.initialTitle,
  });

  @override
  State<_RenameAudioTrackDialog> createState() =>
      _RenameAudioTrackDialogState();
}

class _RenameAudioTrackDialogState extends State<_RenameAudioTrackDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kCardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: _kCardBorder),
      ),
      title: Text(
        'Rename Track #${widget.trackNumber}',
        style: const TextStyle(
          color: _kTextPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        style: const TextStyle(color: _kTextPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'e.g. Malayalam Dolby 5.1',
          hintStyle: const TextStyle(color: _kTextSecondary, fontSize: 13),
          filled: true,
          fillColor: _kSurfaceLight,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _kCardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _kCardBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _kAccent),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: _kTextSecondary),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kAccent,
            foregroundColor: const Color(0xFF04140F),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text(
            'Apply',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

Future<({TmdbMovieSelection selection, String overview})?>
_resolveAndConfirmAiTmdbMatch(
  BuildContext context, {
  required String rawFileName,
  String? existingTitle,
  int? explicitYear,
  String? explicitLanguage,
  TelegramVideoItem? videoItem,
}) async {
  final svc = TelegramStreamService.instance;
  final suggestion = await svc.smartCorrectMetadata(
    rawFileName,
    existingTitle: existingTitle,
    videoItem: videoItem,
  );
  if (!context.mounted) return null;

  final expectedYear = explicitYear ?? suggestion.year;
  final rawLangSource = (explicitLanguage ?? '').trim().isNotEmpty
      ? explicitLanguage!
      : ((videoItem?.language ?? '').trim().isNotEmpty
          ? videoItem!.language!
          : (suggestion.language ?? ''));
  final expectedLangs = rawLangSource
      .split(RegExp(r'[,+/•|]+'))
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();

  final searchQuery = suggestion.searchQuery.trim().isNotEmpty
      ? suggestion.searchQuery.trim()
      : TelegramStreamService.cleanSearchTitle(
          (existingTitle ?? '').trim().isNotEmpty
              ? existingTitle!.trim()
              : rawFileName,
        );

  List<Map<String, dynamic>> candidates = const <Map<String, dynamic>>[];
  if (suggestion.isSeries) {
    final tvRes = await svc.searchTmdbTvPage(searchQuery, page: 1);
    candidates = tvRes.shows;
  }
  if (candidates.isEmpty) {
    final movieRes = await svc.searchTmdbMoviesPage(searchQuery, page: 1);
    candidates = movieRes.movies;
  }
  if (!context.mounted) return null;

  if (candidates.isEmpty) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: _kCardBg,
          content: Text(
            'No matching TMDB movie found. Search manually instead.',
            style: TextStyle(color: Colors.amber, fontWeight: FontWeight.w700),
          ),
        ),
      );
    return null;
  }

  double scoreCandidate(Map<String, dynamic> c) {
    var score = 0.0;
    final candTitle = (c['title'] ?? c['name'] ?? '').toString().trim().toLowerCase();
    if (candTitle == searchQuery.toLowerCase()) score += 12;
    final rd = (c['release_date'] ?? c['first_air_date'] ?? '').toString().trim();
    final cy = rd.length >= 4 ? int.tryParse(rd.substring(0, 4)) : null;
    if (expectedYear != null && cy != null) {
      if (cy == expectedYear) {
        score += 10;
      } else if ((cy - expectedYear).abs() <= 1) {
        score += 4;
      }
    }
    final candLang = TelegramStreamService.mapLanguageCode(
      c['original_language']?.toString(),
    );
    if (candLang != null && expectedLangs.contains(candLang.toLowerCase())) {
      score += 8;
    }
    final pop = (c['popularity'] as num?)?.toDouble() ?? 0.0;
    score += pop.clamp(0.0, 200.0) * 0.01;
    return score;
  }

  final sortedCandidates = List<Map<String, dynamic>>.from(candidates)
    ..sort((a, b) => scoreCandidate(b).compareTo(scoreCandidate(a)));

  var currentIdx = 0;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dlgCtx) => StatefulBuilder(
      builder: (dlgCtx, setDlgState) {
        final best = sortedCandidates[currentIdx];
        final tmdbId =
            (best['id'] is int) ? best['id'] as int : int.tryParse('${best['id']}');
        final tmdbTitle = (best['title'] ?? best['name'] ?? '').toString().trim();
        final rd = (best['release_date'] ?? best['first_air_date'] ?? '')
            .toString()
            .trim();
        final tmdbYear = rd.length >= 4 ? rd.substring(0, 4) : null;
        final tmdbPoster = (best['poster_path'] ?? '').toString().trim();
        final tmdbOverview = (best['overview'] ?? '').toString().trim();
        final candLang = TelegramStreamService.mapLanguageCode(
              best['original_language']?.toString(),
            ) ??
            (best['original_language'] ?? '').toString().trim().toUpperCase();
        final exactYearMatched = expectedYear != null &&
            tmdbYear != null &&
            int.tryParse(tmdbYear) == expectedYear;
        final yearDiffers = expectedYear != null &&
            tmdbYear != null &&
            int.tryParse(tmdbYear) != expectedYear;
        final langMatched = candLang.isNotEmpty &&
            expectedLangs.contains(candLang.toLowerCase());

        return AlertDialog(
          backgroundColor: _kCardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          title: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, color: _kAccentCyan, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'AI Match Found',
                  style: TextStyle(
                    color: _kTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (sortedCandidates.length > 1) ...[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: currentIdx > 0
                      ? () => setDlgState(() => currentIdx--)
                      : null,
                  icon: Icon(
                    Icons.chevron_left_rounded,
                    color: currentIdx > 0 ? _kTextPrimary : Colors.white24,
                    size: 20,
                  ),
                ),
                Text(
                  '${currentIdx + 1}/${sortedCandidates.length}',
                  style: const TextStyle(
                    color: _kTextSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: currentIdx < sortedCandidates.length - 1
                      ? () => setDlgState(() => currentIdx++)
                      : null,
                  icon: Icon(
                    Icons.chevron_right_rounded,
                    color: currentIdx < sortedCandidates.length - 1
                        ? _kTextPrimary
                        : Colors.white24,
                    size: 20,
                  ),
                ),
              ],
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 56,
                      height: 82,
                      child: tmdbPoster.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: '${AppConstants.baseImageUrl}$tmdbPoster',
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                color: _kSurfaceLight,
                                child: const Icon(
                                  Icons.movie_rounded,
                                  color: _kAccentCyan,
                                ),
                              ),
                            )
                          : Container(
                              color: _kSurfaceLight,
                              child: const Icon(
                                Icons.movie_rounded,
                                color: _kAccentCyan,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tmdbTitle.isNotEmpty ? tmdbTitle : 'Movie #$tmdbId',
                          style: const TextStyle(
                            color: _kTextPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: (yearDiffers ? Colors.amber : _kAccent)
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                exactYearMatched
                                    ? 'Year matched ($tmdbYear)'
                                    : (yearDiffers
                                        ? 'File: $expectedYear • TMDB: $tmdbYear'
                                        : (tmdbYear != null
                                            ? 'Release: $tmdbYear'
                                            : 'Release year unknown')),
                                style: TextStyle(
                                  color: yearDiffers ? Colors.amber : _kAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (candLang.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: (langMatched ? _kAccent : _kAccentCyan)
                                      .withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  candLang,
                                  style: TextStyle(
                                    color: langMatched ? _kAccent : _kAccentCyan,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (tmdbOverview.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  tmdbOverview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kTextSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: _kTextSecondary),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: const Color(0xFF04140F),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.pop(dlgCtx, true),
              child: const Text(
                'Confirm & Assign',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        );
      },
    ),
  );

  if (confirmed != true) return null;
  final chosen = sortedCandidates[currentIdx];
  final chosenId = (chosen['id'] is int)
      ? chosen['id'] as int
      : int.tryParse('${chosen['id']}');
  if (chosenId == null) return null;
  final chosenTitle = (chosen['title'] ?? chosen['name'] ?? '').toString().trim();
  final chosenRd =
      (chosen['release_date'] ?? chosen['first_air_date'] ?? '').toString().trim();
  final chosenYear = chosenRd.length >= 4 ? chosenRd.substring(0, 4) : null;
  final chosenPoster = (chosen['poster_path'] ?? '').toString().trim();
  final chosenOverview = (chosen['overview'] ?? '').toString().trim();
  return (
    selection: TmdbMovieSelection(
      id: chosenId,
      title: chosenTitle.isNotEmpty ? chosenTitle : 'Movie #$chosenId',
      posterPath: chosenPoster.isNotEmpty ? chosenPoster : null,
      releaseYear: chosenYear,
    ),
    overview: chosenOverview,
  );
}

/// Opens the owner dialog to configure the optional Gemini API key and
/// AI naming prompt preset.
Future<void> showAiSettingsDialog(BuildContext context) async {
  final svc = TelegramStreamService.instance;
  final existingKey = await svc.getGeminiApiKey();
  final existingPrompt = await svc.getAiPromptPreset();
  if (!context.mounted) return;
  final updated = await showDialog<({String key, String prompt})>(
    context: context,
    builder: (_) => _GeminiApiKeyDialog(
      initialKey: existingKey ?? '',
      initialPrompt: existingPrompt,
    ),
  );
  if (updated == null || !context.mounted) return;
  await svc.setGeminiApiKey(updated.key);
  await svc.setAiPromptPreset(updated.prompt);
  if (!context.mounted) return;
  final cleared = updated.key.trim().isEmpty;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _kCardBg,
        content: Text(
          cleared
              ? 'AI prompt saved (using Pollinations AI)'
              : 'Gemini API key & prompt preset saved',
          style: const TextStyle(color: _kAccent, fontWeight: FontWeight.w700),
        ),
      ),
    );
}

class _GeminiApiKeyDialog extends StatefulWidget {
  final String initialKey;
  final String initialPrompt;

  const _GeminiApiKeyDialog({
    required this.initialKey,
    required this.initialPrompt,
  });

  @override
  State<_GeminiApiKeyDialog> createState() => _GeminiApiKeyDialogState();
}

class _GeminiApiKeyDialogState extends State<_GeminiApiKeyDialog> {
  late final TextEditingController _ctrl;
  late final TextEditingController _promptCtrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialKey);
    _promptCtrl = TextEditingController(text: widget.initialPrompt);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kCardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      title: const Text(
        'AI Key & Prompt Preset',
        style: TextStyle(
          color: _kTextPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Gemini API Key (optional — free at aistudio.google.com/apikey). '
              'Leave empty to use free Pollinations AI automatically.',
              style: TextStyle(
                color: _kTextSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              obscureText: true,
              style: const TextStyle(color: _kTextPrimary, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: 'AIza...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: _kSurfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _kAccent),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Prompt Preset',
                  style: TextStyle(
                    color: _kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                GestureDetector(
                  onTap: () => _promptCtrl.text =
                      TelegramStreamService.defaultAiPromptPreset,
                  child: const Text(
                    'Reset Default',
                    style: TextStyle(
                      color: _kAccent,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _promptCtrl,
              maxLines: 4,
              minLines: 3,
              style: const TextStyle(color: _kTextPrimary, fontSize: 12.5),
              decoration: InputDecoration(
                hintText: TelegramStreamService.defaultAiPromptPreset,
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                filled: true,
                fillColor: _kSurfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _kAccent),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            (key: '', prompt: _promptCtrl.text.trim()),
          ),
          child: const Text(
            'Clear Key',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: _kTextSecondary),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kAccent,
            foregroundColor: const Color(0xFF04140F),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: () => Navigator.pop(
            context,
            (key: _ctrl.text.trim(), prompt: _promptCtrl.text.trim()),
          ),
          child: const Text(
            'Save',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}
