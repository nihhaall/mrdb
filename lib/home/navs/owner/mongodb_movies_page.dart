import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/widgets/movie_collection_sheets.dart';

/// Owner-only page to inspect, delete, or clear all movies stored in MongoDB.
class MongoDbMoviesPage extends StatefulWidget {
  const MongoDbMoviesPage({super.key});

  @override
  State<MongoDbMoviesPage> createState() => _MongoDbMoviesPageState();
}

class _MongoDbMoviesPageState extends State<MongoDbMoviesPage> {
  static const Color _kBgColor = Color(0xFF000000);
  static const Color _kCardBg = Color(0xFF14161F);
  static const Color _kInputBg = Color(0xFF1B1F2C);
  static const Color _kCardBorder = Color(0xFF24283A);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kDanger = Color(0xFFFF5A6E);
  static const Color _kTextPrimary = Color(0xFFF5F7FA);
  static const Color _kTextSecondary = Color(0xFF8E97AB);

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;

  final List<TelegramVideoItem> _movies = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _clearingDb = false;
  bool _hasMore = true;
  int _offset = 0;
  int? _totalCount;
  String? _errorMessage;
  final Set<String> _deletingKeys = <String>{};

  static const int _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMovies(reset: true);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 260 &&
        !_loading &&
        !_loadingMore &&
        _hasMore) {
      _loadMovies(reset: false);
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _loadMovies(reset: true);
    });
  }

  Future<void> _loadMovies({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _errorMessage = null;
        _offset = 0;
        _hasMore = true;
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }

    final q = _searchController.text.trim();
    final res = await TelegramStreamService.instance.fetchBotVideos(
      query: q.isEmpty ? null : q,
      limit: _pageSize,
      offset: reset ? 0 : _offset,
      includeHidden: true,
    );

    if (!mounted) return;
    setState(() {
      if (reset) {
        _movies
          ..clear()
          ..addAll(res.videos);
      } else {
        final existingKeys = _movies.map(_itemKey).toSet();
        for (final v in res.videos) {
          if (existingKeys.add(_itemKey(v))) {
            _movies.add(v);
          }
        }
      }
      _offset = (reset ? 0 : _offset) + res.rawCount;
      _hasMore = res.hasMore;
      if (res.totalCount != null) {
        _totalCount = res.totalCount;
      }
      _errorMessage = res.errorMessage;
      _loading = false;
      _loadingMore = false;
    });
  }

  String _titleOf(TelegramVideoItem item) {
    final t = item.title.trim();
    return t.isNotEmpty ? t : item.fileName;
  }

  String? _thumbOf(TelegramVideoItem item) {
    final poster = (item.tmdbPoster ?? '').trim();
    if (poster.isNotEmpty) {
      return poster.startsWith('http')
          ? poster
          : 'https://image.tmdb.org/t/p/w185$poster';
    }
    final thumb = (item.thumbUrl ?? '').trim();
    return thumb.isNotEmpty ? thumb : null;
  }

  String _itemKey(TelegramVideoItem item) {
    if (item.msgId != null) return 'id:${item.msgId}';
    if (item.streamCode.trim().isNotEmpty) return 'code:${item.streamCode}';
    return 'url:${item.streamUrl}';
  }

  Future<void> _confirmDeleteMovie(TelegramVideoItem item) async {
    final title = _titleOf(item);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Movie from MongoDB?',
          style: TextStyle(color: _kTextPrimary, fontSize: 16.5),
        ),
        content: Text(
          'Remove "$title" (${item.streamCode}) from MongoDB?\n\nUsers will no longer see it in the feed.',
          style: const TextStyle(color: _kTextSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _kTextSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kDanger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final key = _itemKey(item);
    setState(() => _deletingKeys.add(key));
    final ok = await TelegramStreamService.instance.deleteBotVideo(item);
    if (!mounted) return;

    setState(() {
      _deletingKeys.remove(key);
      if (ok) {
        _movies.removeWhere((m) => _itemKey(m) == key);
        if (_totalCount != null && _totalCount! > 0) {
          _totalCount = _totalCount! - 1;
        }
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Deleted "$title" from MongoDB'
              : 'Failed to delete from MongoDB',
        ),
        backgroundColor: ok ? const Color(0xFF15382B) : const Color(0xFF3E1820),
      ),
    );
  }

  Future<void> _confirmClearDb() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: _kDanger, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Clear Entire MongoDB?',
                style: TextStyle(color: _kTextPrimary, fontSize: 16.5),
              ),
            ),
          ],
        ),
        content: Text(
          'This will permanently delete ALL${_totalCount != null ? ' $_totalCount' : ''} saved movies and cached thumbnails from MongoDB.\n\nThis action cannot be undone.',
          style: const TextStyle(color: _kTextSecondary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _kTextSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kDanger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _clearingDb = true);
    final res = await TelegramStreamService.instance.clearBotVideosDb();
    if (!mounted) return;

    setState(() {
      _clearingDb = false;
      if (res.ok) {
        _movies.clear();
        _totalCount = 0;
        _offset = 0;
        _hasMore = false;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? 'Cleared ${res.deletedVideos} movies & ${res.deletedThumbnails} thumbnails from MongoDB'
              : (res.errorMessage ?? 'Failed to clear MongoDB'),
        ),
        backgroundColor:
            res.ok ? const Color(0xFF15382B) : const Color(0xFF3E1820),
      ),
    );
  }

  Future<void> _openEditor(TelegramVideoItem item) async {
    final updated = await Navigator.push<TelegramVideoItem?>(
      context,
      MaterialPageRoute(
        builder: (_) => EditMovieMetadataPage(
          item: item,
          onRequestDelete: () => _confirmDeleteMovie(item),
        ),
      ),
    );
    if (updated != null && mounted) {
      final key = _itemKey(item);
      setState(() {
        final idx = _movies.indexWhere((m) => _itemKey(m) == key);
        if (idx >= 0) {
          _movies[idx] = updated;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final countText = _totalCount != null
        ? '$_totalCount'
        : '${_movies.length}${_hasMore ? '+' : ''}';

    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        iconTheme: const IconThemeData(color: _kTextPrimary),
        title: Row(
          children: [
            const Text(
              'MongoDB Movies',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _kAccent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kAccent.withValues(alpha: 0.45)),
              ),
              child: Text(
                countText,
                style: const TextStyle(
                  color: _kAccent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: TextButton.icon(
              onPressed: _clearingDb ? null : _confirmClearDb,
              style: TextButton.styleFrom(
                foregroundColor: _kDanger,
                backgroundColor: _kDanger.withValues(alpha: 0.12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: _kDanger.withValues(alpha: 0.4)),
                ),
              ),
              icon: _clearingDb
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _kDanger,
                      ),
                    )
                  : const Icon(Icons.delete_sweep_rounded, size: 17),
              label: const Text(
                'Clear DB',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    style: const TextStyle(color: _kTextPrimary, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'Search MongoDB title, filename, code...',
                      hintStyle:
                          const TextStyle(color: _kTextSecondary, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded,
                          color: _kTextSecondary, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded,
                                  color: _kTextSecondary, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                _loadMovies(reset: true);
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: _kInputBg,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
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
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : () => _loadMovies(reset: true),
                  style: IconButton.styleFrom(
                    backgroundColor: _kCardBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: _kCardBorder),
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded, color: _kAccent),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: _kAccent),
                  )
                : _errorMessage != null && _movies.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.cloud_off_rounded,
                                  color: _kTextSecondary, size: 42),
                              const SizedBox(height: 10),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: _kTextSecondary),
                              ),
                              const SizedBox(height: 14),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _kAccent,
                                  foregroundColor: Colors.black,
                                ),
                                onPressed: () => _loadMovies(reset: true),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _movies.isEmpty
                        ? const Center(
                            child: Text(
                              'No movies saved in MongoDB.',
                              style: TextStyle(
                                color: _kTextSecondary,
                                fontSize: 14,
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            color: _kAccent,
                            backgroundColor: _kCardBg,
                            onRefresh: () => _loadMovies(reset: true),
                            child: ListView.separated(
                              controller: _scrollController,
                              padding:
                                  const EdgeInsets.fromLTRB(14, 2, 14, 24),
                              itemCount:
                                  _movies.length + (_loadingMore ? 1 : 0),
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                if (index >= _movies.length) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 16),
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        color: _kAccent,
                                        strokeWidth: 2.2,
                                      ),
                                    ),
                                  );
                                }
                                final item = _movies[index];
                                return _buildMovieTile(item);
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildMovieTile(TelegramVideoItem item) {
    final key = _itemKey(item);
    final isDeleting = _deletingKeys.contains(key);
    final thumbUrl = _thumbOf(item);
    final title = _titleOf(item);
    final showRawName =
        item.fileName.trim().isNotEmpty && item.fileName.trim() != title;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        HapticFeedback.selectionClick();
        _openEditor(item);
      },
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kCardBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Container(
                width: 52,
                height: 74,
                color: _kInputBg,
                child: thumbUrl != null && thumbUrl.isNotEmpty
                    ? Image.network(
                        thumbUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.movie_rounded,
                          color: _kTextSecondary,
                          size: 24,
                        ),
                      )
                    : const Icon(
                        Icons.movie_rounded,
                        color: _kTextSecondary,
                        size: 24,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (showRawName) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _kTextSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _badge(
                        item.msgId != null ? 'ID ${item.msgId}' : item.streamCode,
                        _kTextSecondary,
                      ),
                      if (item.fileSize > 0)
                        _badge(
                          TelegramStreamService.formatBytes(item.fileSize),
                          _kAccent,
                        ),
                      if (item.tmdbId != null)
                        _badge('TMDB ${item.tmdbId}', Colors.lightBlueAccent),
                      if (item.hiddenForUsers)
                        _badge('Hidden', Colors.amber),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Delete Movie',
              onPressed: isDeleting ? null : () => _confirmDeleteMovie(item),
              style: IconButton.styleFrom(
                backgroundColor: _kDanger.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: isDeleting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _kDanger,
                      ),
                    )
                  : const Icon(
                      Icons.delete_outline_rounded,
                      color: _kDanger,
                      size: 20,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
