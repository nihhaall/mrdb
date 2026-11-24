import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/models/movie_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:provider/provider.dart' as p;
import 'package:shimmer/shimmer.dart';
import '../../../main.dart';
import '../../../provider/client.dart';
import '../../../splash.dart';

class HomePage extends ConsumerStatefulWidget {
  final String? lang;
  const HomePage({super.key, this.lang});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  // State variables
  bool _showFAB = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  bool _isSearching = false;
  double _scrollPixel = 0;

  // Release Category
  HomeReleaseCategory _releaseCategory = HomeReleaseCategory.nowReleased;

  // Language settings (default is null for 'All')
  String? _selectedLangCode;
  final List<Map<String, dynamic>> _languages = [
    {'code': null, 'name': 'All', 'flag': '🌐'},
    {'code': 'en', 'name': 'English', 'flag': '🇬🇧'},
    {'code': 'ml', 'name': 'Malayalam', 'flag': '🇮🇳'},
    {'code': 'ta', 'name': 'Tamil', 'flag': '🇮🇳'},
    {'code': 'hi', 'name': 'Hindi', 'flag': '🇮🇳'},
    {'code': 'kn', 'name': 'Kannada', 'flag': '🇮🇳'},
    {'code': 'ja', 'name': 'Japanese', 'flag': '🇯🇵'},
    {'code': 'de', 'name': 'German', 'flag': '🇩🇪'},
    {'code': 'ko', 'name': 'Korean', 'flag': '🇰🇷'},
    {'code': 'pt', 'name': 'Portuguese', 'flag': '🇧🇷'},
  ];

  // Genre settings
  final Set<int> _selectedGenreIds = {};
  final List<Map<String, dynamic>> _genres = [
    {'id': 28, 'name': 'Action', 'icon': Icons.flash_on_rounded},
    {'id': 12, 'name': 'Adventure', 'icon': Icons.explore_rounded},
    {'id': 16, 'name': 'Animation', 'icon': Icons.animation_rounded},
    {
      'id': 35,
      'name': 'Comedy',
      'icon': Icons.sentiment_very_satisfied_rounded,
    },
    {'id': 80, 'name': 'Crime', 'icon': Icons.local_police_rounded},
    {'id': 99, 'name': 'Documentary', 'icon': Icons.menu_book_rounded},
    {'id': 18, 'name': 'Drama', 'icon': Icons.theater_comedy_rounded},
    {'id': 10751, 'name': 'Family', 'icon': Icons.family_restroom_rounded},
    {'id': 14, 'name': 'Fantasy', 'icon': Icons.auto_fix_high_rounded},
    {'id': 27, 'name': 'Horror', 'icon': Icons.nightlight_round},
    {'id': 10402, 'name': 'Music', 'icon': Icons.music_note_rounded},
    {'id': 9648, 'name': 'Mystery', 'icon': Icons.search_rounded},
    {'id': 10749, 'name': 'Romance', 'icon': Icons.favorite_rounded},
    {'id': 878, 'name': 'Sci-Fi', 'icon': Icons.rocket_launch_rounded},
    {'id': 53, 'name': 'Thriller', 'icon': Icons.warning_amber_rounded},
    {'id': 10752, 'name': 'War', 'icon': Icons.military_tech_rounded},
  ];

  // Data
  List<dynamic> _movies = [];
  List<int> _likedMovieIds = [];
  final Set<int> _likingInProgress = {};

  // Controllers
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Device info
  String _deviceId = '';

  // Constants
  static const int _maxRetryAttempts = 3;
  static const Duration _retryDelay = Duration(seconds: 1);
  static const double _fabShowThreshold = 800;
  static const double _loadMoreThreshold = 150;

  @override
  void initState() {
    super.initState();
    _selectedLangCode = widget.lang;
    _releaseCategory = ref.read(homeReleaseCategoryProvider);
    _initializeData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeData() async {
    _deviceId =
        p.Provider.of<ClientProvider>(context, listen: false).clientId ?? '';
    await Future.wait([_fetchMovies(isInitialLoad: true), _fetchLikedMovies()]);
  }

  Future<void> _fetchMovies({
    bool isInitialLoad = false,
    bool isRefresh = false,
    bool isLoadMore = false,
  }) async {
    if (isLoadMore && (_isLoadingMore || !mounted)) return;

    setState(() {
      if (isInitialLoad || isRefresh) {
        _isLoading = true;
        _hasError = false;
        pageNum = 1;
      }
      if (isLoadMore) {
        _isLoadingMore = true;
      }
    });

    final url = _buildMovieUrl();

    for (int attempt = 0; attempt < _maxRetryAttempts; attempt++) {
      try {
        final response = await http
            .get(url)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw TimeoutException('Request timed out'),
            );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final results = data['results'] as List<dynamic>? ?? [];

          if (!mounted) return;

          setState(() {
            if (isLoadMore) {
              _movies.addAll(results);
            } else {
              _movies = results;
            }
            _isLoading = false;
            _isLoadingMore = false;
            _hasError = false;
          });
          return;
        } else {
          throw HttpException('Failed with status: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Movie fetch error (attempt ${attempt + 1}): $e');
        if (attempt < _maxRetryAttempts - 1) {
          await Future.delayed(_retryDelay);
        } else {
          _handleFetchError();
        }
      }
    }
  }

  Uri _buildMovieUrl() {
    final today = DateTime.now().toIso8601String().split('T').first;
    final nextYear = DateTime.now()
        .add(const Duration(days: 365))
        .toIso8601String()
        .split('T')
        .first;

    final langParam =
        (_selectedLangCode != null && _selectedLangCode!.isNotEmpty)
        ? '&with_original_language=$_selectedLangCode'
        : '';
    final genreParam = _selectedGenreIds.isNotEmpty
        ? '&with_genres=${_selectedGenreIds.join(',')}'
        : '';

    String dateParam = '';
    if (_releaseCategory == HomeReleaseCategory.upcoming) {
      dateParam =
          '&primary_release_date.gte=$today&primary_release_date.lte=$nextYear';
    } else {
      dateParam = '&primary_release_date.lte=$today';
    }

    return Uri.parse(
      'https://api.themoviedb.org/3/discover/movie'
      '?api_key=${AppConstants.apiKey}'
      '$langParam'
      '$genreParam'
      '$dateParam'
      '&sort_by=popularity.desc'
      '&page=$pageNum',
    );
  }

  void _handleFetchError() {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isLoadingMore = false;
      _hasError = _movies.isEmpty;
      _scrollPixel = 0;
      if (_isLoadingMore) _showFAB = true;
    });
    _showMessage('Failed to load movies. Please try again.');
  }

  Future<void> _searchMovies(String query) async {
    final trimmedQuery = query.trim();

    if (trimmedQuery.isEmpty) {
      _onRefresh();
      return;
    }

    if (!mounted) return;
    setState(() {
      _showFAB = false;
      _isLoading = true;
      _hasError = false;
      _isSearching = true;
    });

    final url = Uri.parse(
      'https://api.themoviedb.org/3/search/movie'
      '?api_key=${AppConstants.apiKey}'
      '&query=${Uri.encodeComponent(trimmedQuery)}',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            _movies = data['results'] as List<dynamic>? ?? [];
            pageNum = 1;
            _isLoading = false;
            _scrollToTop(animate: false);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
        _showMessage('Search failed.');
      }
    }
  }

  Future<void> _fetchLikedMovies() async {
    if (_deviceId.isEmpty) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_deviceId)
          .collection('liked')
          .where('delete', isEqualTo: false)
          .get();

      if (mounted) {
        setState(() {
          _likedMovieIds = snapshot.docs
              .map((doc) => int.tryParse(doc['id'].toString()) ?? -1)
              .where((id) => id != -1)
              .toList();
        });
      }
    } catch (e) {
      debugPrint('Fetch liked error: $e');
    }
  }

  Future<void> _addToFavorites({
    required int movieId,
    required String title,
    required String? posterPath,
    required String? releaseDate,
    required double rating,
  }) async {
    if (_likedMovieIds.contains(movieId)) {
      _showMessage('Go to Favorites to remove this movie');
      return;
    }

    if (_likingInProgress.contains(movieId)) return;
    setState(() => _likingInProgress.add(movieId));

    final movie = Movie(
      movId: movieId,
      title: title,
      img: posterPath != null ? '${AppConstants.baseImageUrl}$posterPath' : '',
      year: releaseDate ?? '',
      rating: rating,
      timeStamp: DateTime.now(),
      delete: false,
    );

    try {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_deviceId)
          .collection('liked')
          .doc(movieId.toString())
          .set(movie.toMap());

      if (mounted) {
        setState(() {
          _likedMovieIds.add(movieId);
          _likingInProgress.remove(movieId);
        });
        _showMessage('"$title" added to favorites ✅');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _likingInProgress.remove(movieId));
        _showMessage('Failed to add to favorites ❌');
      }
    }
  }

  // ==================== UI LOGIC ====================

  void _onLanguageChange(String? code) {
    if (_selectedLangCode == code) return;
    setState(() {
      _selectedLangCode = code;
      _movies.clear();
      _isSearching = false;
      _searchController.clear();
    });
    _fetchMovies(isInitialLoad: true);
  }

  void _toggleGenre(int genreId) {
    setState(() {
      if (_selectedGenreIds.contains(genreId)) {
        _selectedGenreIds.remove(genreId);
      } else {
        _selectedGenreIds.add(genreId);
      }
      _movies.clear();
      _isSearching = false;
      _searchController.clear();
    });
    _fetchMovies(isInitialLoad: true);
  }

  void _clearGenres() {
    if (_selectedGenreIds.isEmpty) return;
    setState(() {
      _selectedGenreIds.clear();
      _movies.clear();
      _isSearching = false;
      _searchController.clear();
    });
    _fetchMovies(isInitialLoad: true);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showScaffoldMsg(context, txt: message);
  }

  void _scrollToTop({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    if (animate) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.fastEaseInToSlowEaseOut,
      );
    } else {
      _scrollController.jumpTo(0);
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _scrollPixel = notification.metrics.pixels;

    final shouldShowFAB = _scrollPixel > _fabShowThreshold;
    if (shouldShowFAB != _showFAB && mounted) {
      setState(() => _showFAB = shouldShowFAB);
    }

    final isNearBottom =
        _scrollPixel >=
        notification.metrics.maxScrollExtent - _loadMoreThreshold;
    if (isNearBottom && !_isLoadingMore && !_isLoading && !_isSearching) {
      pageNum++;
      _fetchMovies(isLoadMore: true).catchError((_) {
        pageNum--;
      });
    }
    return true;
  }

  Future<void> _onRefresh() async {
    setState(() {
      _isSearching = false;
      _searchController.clear();
    });
    await _fetchMovies(isRefresh: true);
    _scrollToTop(animate: false);
  }

  bool tap = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<HomeReleaseCategory>(homeReleaseCategoryProvider, (prev, next) {
      if (prev != next) {
        setState(() {
          _releaseCategory = next;
          _movies.clear();
          _isSearching = false;
          _searchController.clear();
        });
        _fetchMovies(isInitialLoad: true);
        _scrollToTop(animate: true);
      }
    });

    return PopScope(
      canPop: tap,
      onPopInvokedWithResult: (didPop, result) async {
        if (!tap) {
          Fluttertoast.showToast(
            msg: 'Press back again to exit',
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
          );
        }
        setState(() {
          tap = true;
        });
        await Future.delayed(const Duration(seconds: 2));
        setState(() {
          tap = false;
        });
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        floatingActionButton: _showFAB
            ? Padding(
                padding: EdgeInsets.symmetric(
                  vertical: wt * 0.03,
                  horizontal: wt * 0.01,
                ),
                child: FloatingActionButton(
                  onPressed: _scrollToTop,
                  backgroundColor: Colors.white70,
                  child: const Icon(Icons.arrow_upward, color: Colors.black),
                ),
              )
            : null,
        appBar: AppBar(
          backgroundColor: Colors.black,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleSpacing: wt * 0.04,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _releaseCategory == HomeReleaseCategory.upcoming
                        ? [const Color(0xFFFF9F1C), const Color(0xFFFF6B6B)]
                        : [const Color(0xFF00E676), const Color(0xFF00B0FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: [
                    BoxShadow(
                      color: (_releaseCategory == HomeReleaseCategory.upcoming
                              ? const Color(0xFFFF9F1C)
                              : const Color(0xFF00E676))
                          .withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Text(
                  'M',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RichText(
                text: TextSpan(
                  children: [
                    const TextSpan(
                      text: 'MR',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                    TextSpan(
                      text: 'Db',
                      style: TextStyle(
                        color: _releaseCategory == HomeReleaseCategory.upcoming
                            ? const Color(0xFFFF9F1C)
                            : const Color(0xFF00E676),
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: _hasError
            ? Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(wt * 0.1),
                  onTap: _initializeData,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: wt * 0.05,
                      vertical: wt * 0.025,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade700,
                      borderRadius: BorderRadius.circular(wt * 0.1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Amicons.vuesax_refresh_circle_fill,
                          size: wt * 0.07,
                          color: Colors.white54,
                        ),
                        SizedBox(width: wt * 0.02),
                        const Text(
                          'Retry',
                          style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : NotificationListener<ScrollNotification>(
                onNotification: _handleScrollNotification,
                child: RefreshIndicator(
                  onRefresh: _onRefresh,
                  color: Colors.green,
                  backgroundColor: Colors.grey.shade900,
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      // 1. Search Bar
                      SliverToBoxAdapter(child: _buildSearchBar()),

                      // 2. Section Header with Language and Genre filter badges
                      SliverToBoxAdapter(child: _buildSectionHeader()),

                      // 4. Grid View
                      _isLoading
                          ? SliverToBoxAdapter(child: _buildShimmerLoading())
                          : (_movies.isEmpty
                                ? SliverToBoxAdapter(child: _buildEmptyState())
                                : SliverPadding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: wt * 0.04,
                                    ),
                                    sliver: SliverGrid(
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 2,
                                            mainAxisSpacing: ht * 0.02,
                                            crossAxisSpacing: wt * 0.04,
                                            mainAxisExtent: wt * 0.9,
                                          ),
                                      delegate: SliverChildBuilderDelegate((
                                        context,
                                        index,
                                      ) {
                                        return _MovieCard(
                                          movie: _movies[index],
                                          isLiked: _likedMovieIds.contains(
                                            _movies[index]['id'],
                                          ),
                                          isLiking: _likingInProgress.contains(
                                            _movies[index]['id'],
                                          ),
                                          onTap: () => _navigateToPreview(
                                            _movies[index],
                                          ),
                                          onFavorite: () => _addToFavorites(
                                            movieId: _movies[index]['id'],
                                            title:
                                                _movies[index]['title'] ?? '',
                                            posterPath:
                                                _movies[index]['poster_path'],
                                            releaseDate:
                                                _movies[index]['release_date'],
                                            rating:
                                                (_movies[index]['vote_average'] ??
                                                        0)
                                                    .toDouble(),
                                          ),
                                        );
                                      }, childCount: _movies.length),
                                    ),
                                  )),

                      // 6. Pagination Loader
                      if (_isLoadingMore)
                        SliverToBoxAdapter(child: _buildLoadingMoreIndicator()),

                      // Bottom padding
                      SliverToBoxAdapter(child: SizedBox(height: ht * 0.05)),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  // ── Search Bar ─────────────────────────────────────────────────────────────
  Widget _buildSearchBar() {
    final bool isUpcoming = _releaseCategory == HomeReleaseCategory.upcoming;
    final Color themeAccent =
        isUpcoming ? const Color(0xFFFF9F1C) : const Color(0xFF00E676);

    return Padding(
      padding:
          EdgeInsets.fromLTRB(wt * 0.04, wt * 0.015, wt * 0.04, wt * 0.02),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF141824),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _isSearching
                ? themeAccent.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.08),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
            if (_isSearching)
              BoxShadow(
                color: themeAccent.withValues(alpha: 0.12),
                blurRadius: 12,
                spreadRadius: 1,
              ),
          ],
        ),
        child: TextFormField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onFieldSubmitted: _searchMovies,
          onChanged: (val) {
            setState(() {});
          },
          cursorColor: themeAccent,
          cursorHeight: ht * 0.024,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 14.5,
          ),
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 13,
            ),
            hintText: isUpcoming
                ? 'Search upcoming releases...'
                : 'Search movies, genres, cast...',
            hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontWeight: FontWeight.normal,
              fontSize: 14,
            ),
            prefixIcon: Container(
              margin: const EdgeInsets.only(
                left: 10,
                right: 10,
                top: 7,
                bottom: 7,
              ),
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: _isSearching
                    ? themeAccent.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.search_rounded,
                color: _isSearching ? themeAccent : Colors.white70,
                size: 19,
              ),
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: 44,
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            _searchController.clear();
                            setState(() {});
                            _onRefresh();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                              size: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            _searchMovies(_searchController.text);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: isUpcoming
                                    ? [
                                        const Color(0xFFFF9F1C),
                                        const Color(0xFFFF6B6B),
                                      ]
                                    : [
                                        const Color(0xFF00E676),
                                        const Color(0xFF00B0FF),
                                      ],
                              ),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: themeAccent.withValues(alpha: 0.3),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.black,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  // ── Section header with compact Language & Genre badges ───────────────────
  Widget _buildSectionHeader() {
    final currentLang = _languages.firstWhere(
      (l) => l['code'] == _selectedLangCode,
      orElse: () => _languages.first,
    );

    String genreLabel;
    if (_selectedGenreIds.isEmpty) {
      genreLabel = 'Genre';
    } else if (_selectedGenreIds.length == 1) {
      final matched = _genres.firstWhere(
        (g) => g['id'] == _selectedGenreIds.first,
        orElse: () => _genres.first,
      );
      genreLabel = matched['name'] as String;
    } else {
      genreLabel = '${_selectedGenreIds.length} Genres';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        wt * 0.035,
        wt * 0.02,
        wt * 0.035,
        wt * 0.025,
      ),
      child: Row(
        children: [
          Container(
            width: 3.5,
            height: 18,
            decoration: BoxDecoration(
              color: _releaseCategory == HomeReleaseCategory.upcoming
                  ? const Color(0xFFFF9F1C)
                  : Colors.green,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _isSearching
                ? 'Search Results'
                : (_releaseCategory == HomeReleaseCategory.upcoming
                    ? 'Upcoming Movies'
                    : 'Discover'),
            style: TextStyle(
              color: Colors.white,
              fontSize: wt * 0.046,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          if (!_isSearching) ...[
            // Genre Filter Badge
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _showGenreBottomSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _selectedGenreIds.isNotEmpty
                      ? Colors.green.withValues(alpha: 0.15)
                      : const Color(0xFF191D26),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _selectedGenreIds.isNotEmpty
                        ? Colors.green
                        : Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _selectedGenreIds.isNotEmpty
                          ? Icons.check_circle_outline_rounded
                          : Icons.movie_filter_rounded,
                      color: _selectedGenreIds.isNotEmpty
                          ? Colors.green
                          : Colors.white70,
                      size: 13,
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 72),
                      child: Text(
                        genreLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _selectedGenreIds.isNotEmpty
                              ? Colors.green
                              : Colors.white,
                          fontSize: wt * 0.027,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: _selectedGenreIds.isNotEmpty
                          ? Colors.green
                          : Colors.white54,
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Language Filter Badge
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _showLanguageBottomSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _selectedLangCode != null
                      ? Colors.green.withValues(alpha: 0.15)
                      : const Color(0xFF191D26),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _selectedLangCode != null
                        ? Colors.green
                        : Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      currentLang['flag'] as String? ?? '🌐',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 60),
                      child: Text(
                        currentLang['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _selectedLangCode != null
                              ? Colors.green
                              : Colors.white,
                          fontSize: wt * 0.027,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: _selectedLangCode != null
                          ? Colors.green
                          : Colors.white54,
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Bottom Sheet Genre Multi-Picker ───────────────────────────────────────
  void _showGenreBottomSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF14171F),
      barrierColor: Colors.black.withValues(alpha: 0.65),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: wt * 0.05,
                  vertical: wt * 0.03,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    SizedBox(height: wt * 0.04),
                    Row(
                      children: [
                        const Icon(
                          Icons.movie_filter_rounded,
                          color: Colors.green,
                          size: 20,
                        ),
                        SizedBox(width: wt * 0.02),
                        Text(
                          'Select Genres',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: wt * 0.044,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_selectedGenreIds.isNotEmpty) ...[
                          SizedBox(width: wt * 0.02),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${_selectedGenreIds.length}',
                              style: const TextStyle(
                                color: Colors.green,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (_selectedGenreIds.isNotEmpty)
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              setSheetState(() {
                                _clearGenres();
                              });
                            },
                            child: const Text(
                              'Reset',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: wt * 0.035),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: ht * 0.42),
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Wrap(
                          spacing: wt * 0.025,
                          runSpacing: wt * 0.025,
                          children: _genres.map((genre) {
                            final isSelected =
                                _selectedGenreIds.contains(genre['id']);
                            return InkWell(
                              borderRadius: BorderRadius.circular(wt * 0.035),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setSheetState(() {
                                  _toggleGenre(genre['id'] as int);
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: EdgeInsets.symmetric(
                                  horizontal: wt * 0.032,
                                  vertical: wt * 0.02,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.green.withValues(alpha: 0.16)
                                      : const Color(0xFF191D26),
                                  borderRadius:
                                      BorderRadius.circular(wt * 0.035),
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.green
                                        : Colors.white.withValues(alpha: 0.08),
                                    width: 1.2,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      genre['icon'] as IconData,
                                      size: wt * 0.036,
                                      color: isSelected
                                          ? Colors.green
                                          : Colors.white60,
                                    ),
                                    SizedBox(width: wt * 0.015),
                                    Text(
                                      genre['name'] as String,
                                      style: TextStyle(
                                        color: isSelected
                                            ? Colors.green
                                            : Colors.white70,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        fontSize: wt * 0.032,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    SizedBox(height: wt * 0.04),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.black,
                          padding: EdgeInsets.symmetric(vertical: wt * 0.032),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(wt * 0.035),
                          ),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          'Apply Filters',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: wt * 0.02),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── Bottom Sheet Language Picker ──────────────────────────────────────────
  void _showLanguageBottomSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF14171F),
      barrierColor: Colors.black.withValues(alpha: 0.65),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: wt * 0.05,
              vertical: wt * 0.03,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                SizedBox(height: wt * 0.04),
                Row(
                  children: [
                    const Icon(
                      Icons.translate_rounded,
                      color: Colors.green,
                      size: 20,
                    ),
                    SizedBox(width: wt * 0.02),
                    Text(
                      'Select Language',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: wt * 0.044,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: wt * 0.035),
                Wrap(
                  spacing: wt * 0.025,
                  runSpacing: wt * 0.025,
                  children: _languages.map((lang) {
                    final isSelected = _selectedLangCode == lang['code'];
                    return InkWell(
                      borderRadius: BorderRadius.circular(wt * 0.04),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(ctx);
                        _onLanguageChange(lang['code'] as String?);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: EdgeInsets.symmetric(
                          horizontal: wt * 0.035,
                          vertical: wt * 0.022,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.green.withValues(alpha: 0.16)
                              : const Color(0xFF191D26),
                          borderRadius: BorderRadius.circular(wt * 0.04),
                          border: Border.all(
                            color: isSelected
                                ? Colors.green
                                : Colors.white.withValues(alpha: 0.08),
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              lang['flag'] as String? ?? '🌐',
                              style: TextStyle(fontSize: wt * 0.038),
                            ),
                            SizedBox(width: wt * 0.02),
                            Text(
                              lang['name'] as String,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.green
                                    : Colors.white70,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                fontSize: wt * 0.034,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                SizedBox(height: wt * 0.04),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: ht * 0.05),
          Icon(
            Amicons.iconly_video,
            size: wt * 0.2,
            color: Colors.grey.shade600,
          ),
          SizedBox(height: ht * 0.02),
          Text(
            _releaseCategory == HomeReleaseCategory.upcoming
                ? 'No upcoming movies found'
                : 'No movies found',
            style: TextStyle(color: Colors.grey.shade500, fontSize: wt * 0.045),
          ),
          SizedBox(height: ht * 0.01),
          Text(
            'Try changing the language or searching for a title',
            style: TextStyle(color: Colors.grey.shade600, fontSize: wt * 0.032),
          ),
          SizedBox(height: ht * 0.05),
        ],
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer(
      direction: ShimmerDirection.rtl,
      period: const Duration(milliseconds: 700),
      gradient: LinearGradient(
        colors: [
          Colors.grey.shade800,
          Colors.grey.shade600,
          Colors.grey.shade800,
        ],
        stops: const [0.0, 0.5, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 4,
        padding: EdgeInsets.symmetric(horizontal: wt * 0.04),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: ht * 0.02,
          crossAxisSpacing: wt * 0.04,
          mainAxisExtent: wt * 0.7,
        ),
        itemBuilder: (context, index) => Container(
          decoration: BoxDecoration(
            color: Colors.white38,
            borderRadius: BorderRadius.circular(wt * 0.04),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingMoreIndicator() {
    return Container(
      padding: EdgeInsets.all(wt * 0.05),
      child: Center(
        child: LoadingAnimationWidget.progressiveDots(
          color: const Color(0xFF00E5A0),
          size: wt * 0.1,
        ),
      ),
    );
  }

  void _navigateToPreview(dynamic movieData) {
    final Map<String, dynamic>? movie = (movieData is Map<String, dynamic>)
        ? movieData
        : null;
    final String movieId = movie != null
        ? movie['id'].toString()
        : movieData.toString();

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (context, animation, secondaryAnimation) {
          return MoviePreview(
            movieId: movieId,
            initialMovie: movie,
            posterPath: movie?['poster_path'],
            title: movie?['title'] ?? movie?['name'],
            backdropPath: movie?['backdrop_path'],
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }
}

class _MovieCard extends StatelessWidget {
  final Map<String, dynamic> movie;
  final bool isLiked;
  final bool isLiking;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  const _MovieCard({
    required this.movie,
    required this.isLiked,
    required this.isLiking,
    required this.onTap,
    required this.onFavorite,
  });

  Widget _buildTitleFlightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final Widget fromChild = (fromHeroContext.widget is Hero)
        ? (fromHeroContext.widget as Hero).child
        : fromHeroContext.widget;
    final Widget toChild = (toHeroContext.widget is Hero)
        ? (toHeroContext.widget as Hero).child
        : toHeroContext.widget;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final double progress = animation.value;
        final double fromOpacity = (1.0 - (progress * 1.8)).clamp(0.0, 1.0);
        final double toOpacity = ((progress - 0.35) * 1.5).clamp(0.0, 1.0);

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            alignment: Alignment.centerLeft,
            fit: StackFit.passthrough,
            children: [
              if (fromOpacity > 0.0)
                Opacity(
                  opacity: fromOpacity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: fromChild,
                  ),
                ),
              if (toOpacity > 0.0)
                Opacity(
                  opacity: toOpacity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: toChild,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final posterPath = movie['poster_path'];
    final title = movie['title'] ?? movie['name'] ?? 'Unknown';
    final releaseDate = (movie['release_date'] ?? '').toString();
    final voteAverage = (movie['vote_average'] ?? 0).toDouble();
    final rating = voteAverage / 2;

    bool isUpcoming = false;
    String upcomingDateFormatted = '';
    if (releaseDate.isNotEmpty) {
      try {
        final parsedDate = DateTime.tryParse(releaseDate);
        if (parsedDate != null && parsedDate.isAfter(DateTime.now())) {
          isUpcoming = true;
          const months = [
            'Jan',
            'Feb',
            'Mar',
            'Apr',
            'May',
            'Jun',
            'Jul',
            'Aug',
            'Sep',
            'Oct',
            'Nov',
            'Dec',
          ];
          upcomingDateFormatted =
              '${months[parsedDate.month - 1]} ${parsedDate.day}';
        }
      } catch (_) {}
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(wt * 0.045),
          border: Border.all(
            color: Colors.grey.shade800.withValues(alpha: 0.3),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            // Poster Image with gradient overlay
            Expanded(
              flex: 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: 'movie_hero_${movie['id']}',
                    child: Material(
                      type: MaterialType.transparency,
                      child: _buildPosterImage(posterPath),
                    ),
                  ),
                  _buildGradientOverlay(),
                  _buildFavoriteButton(),
                  if (isUpcoming && upcomingDateFormatted.isNotEmpty)
                    _buildUpcomingBadge(upcomingDateFormatted)
                  else if (rating > 0)
                    _buildRatingBadge(rating),
                ],
              ),
            ),
            // Title & Release Date
            Expanded(
              flex: 3,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: wt * 0.025,
                  vertical: wt * 0.02,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Hero(
                      tag: 'movie_title_${movie['id']}',
                      flightShuttleBuilder: _buildTitleFlightShuttle,
                      child: Material(
                        type: MaterialType.transparency,
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: wt * 0.038,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: wt * 0.01),
                    Row(
                      children: [
                        Icon(
                          isUpcoming
                              ? Icons.hourglass_top_rounded
                              : Icons.calendar_today,
                          size: wt * 0.028,
                          color: isUpcoming
                              ? const Color(0xFFFF9F1C)
                              : Colors.white54,
                        ),
                        SizedBox(width: wt * 0.01),
                        Text(
                          isUpcoming && upcomingDateFormatted.isNotEmpty
                              ? upcomingDateFormatted
                              : (releaseDate.contains('-')
                                    ? releaseDate.split('-').first
                                    : releaseDate),
                          style: TextStyle(
                            color: isUpcoming
                                ? const Color(0xFFFF9F1C)
                                : Colors.white54,
                            fontSize: wt * 0.03,
                            fontWeight: FontWeight.w500,
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
    );
  }

  Widget _buildPosterImage(String? posterPath) {
    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(wt * 0.045),
        topRight: Radius.circular(wt * 0.045),
      ),
      child: posterPath != null
          ? CachedNetworkImage(
              imageUrl: 'https://image.tmdb.org/t/p/w500$posterPath',
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                color: Colors.grey.shade900,
                child: Center(
                  child: LoadingAnimationWidget.fallingDot(
                    color: Colors.green,
                    size: wt * 0.1,
                  ),
                ),
              ),
              errorWidget: (context, url, error) => _buildErrorImage(),
            )
          : _buildErrorImage(),
    );
  }

  Widget _buildErrorImage() {
    return Container(
      color: Colors.grey.shade900,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.movie_outlined,
              color: Colors.grey.shade700,
              size: wt * 0.12,
            ),
            SizedBox(height: wt * 0.02),
            Text(
              'No Image',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: wt * 0.03,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGradientOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: wt * 0.3,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
          ),
        ),
      ),
    );
  }

  Widget _buildFavoriteButton() {
    return Positioned(
      top: wt * 0.02,
      right: wt * 0.02,
      child: GestureDetector(
        onTap: onFavorite,
        child: Container(
          width: wt * 0.10,
          height: wt * 0.10,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(wt * 0.025),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: isLiking
                ? LoadingAnimationWidget.fallingDot(
                    color: Colors.red,
                    size: wt * 0.05,
                  )
                : Icon(
                    isLiked ? Amicons.iconly_heart_fill : Amicons.iconly_heart,
                    color: isLiked ? Colors.red : Colors.white,
                    size: wt * 0.048,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildUpcomingBadge(String dateText) {
    return Positioned(
      bottom: wt * 0.02,
      left: wt * 0.02,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: wt * 0.025,
          vertical: wt * 0.012,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(wt * 0.02),
          border: Border.all(
            color: const Color(0xFFFF9F1C).withValues(alpha: 0.7),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF9F1C).withValues(alpha: 0.2),
              blurRadius: 6,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_top_rounded,
              color: const Color(0xFFFF9F1C),
              size: wt * 0.034,
            ),
            SizedBox(width: wt * 0.01),
            Text(
              dateText,
              style: TextStyle(
                color: const Color(0xFFFF9F1C),
                fontSize: wt * 0.028,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRatingBadge(double rating) {
    return Positioned(
      bottom: wt * 0.02,
      left: wt * 0.02,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: wt * 0.025,
          vertical: wt * 0.015,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(wt * 0.02),
          border: Border.all(
            color: _getRatingColor(rating).withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.star_rounded,
              color: _getRatingColor(rating),
              size: wt * 0.04,
            ),
            SizedBox(width: wt * 0.01),
            Text(
              rating.toStringAsFixed(1),
              style: TextStyle(
                color: Colors.white,
                fontSize: wt * 0.032,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getRatingColor(double rating) {
    if (rating >= 4.0) return const Color(0xFF4CAF50);
    if (rating >= 3.0) return const Color(0xFFFFC107);
    if (rating >= 2.0) return const Color(0xFFFF9800);
    return const Color(0xFFF44336);
  }
}
