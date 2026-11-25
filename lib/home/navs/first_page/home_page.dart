import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/home/navs/first_page/random_movie_page.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';
import 'package:provider/provider.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import '../../../main.dart';
import '../../../provider/favorites_provider.dart';
import '../../../splash.dart';

class HomePage extends ConsumerStatefulWidget {
  final String? lang;
  const HomePage({super.key, this.lang});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  // State variables
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  bool _isSearching = false;
  bool _isSlowConnection = false;
  bool _isShowingCached = false;
  NetworkFailureType _failureType = NetworkFailureType.none;
  String? _errorMessage;
  NetworkFailureType _loadMoreFailureType = NetworkFailureType.none;
  String? _loadMoreErrorMessage;

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
    {'code': 'te', 'name': 'Telugu', 'flag': '🇮🇳'},
    {'code': 'kn', 'name': 'Kannada', 'flag': '🇮🇳'},
    {'code': 'ja', 'name': 'Japanese', 'flag': '🇯🇵'},
    {'code': 'ko', 'name': 'Korean', 'flag': '🇰🇷'},
    {'code': 'es', 'name': 'Spanish', 'flag': '🇪🇸'},
    {'code': 'fr', 'name': 'French', 'flag': '🇫🇷'},
    {'code': 'de', 'name': 'German', 'flag': '🇩🇪'},
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

  // Controllers
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final PageController _heroCarouselController = PageController();
  final ValueNotifier<bool> _showScrollToTop = ValueNotifier<bool>(false);
  int _currentHeroPage = 0;
  Timer? _heroTimer;
  Timer? _reconnectTimer;
  bool _isCheckingReconnect = false;
  int _imageRetryEpoch = 0;

  // Constants
  static const int _maxRetryAttempts = 3;
  static const Duration _retryDelay = Duration(seconds: 1);
  static const double _scrollToTopThreshold = 420;
  static const double _loadMoreThreshold = 150;

  @override
  void initState() {
    super.initState();
    _selectedLangCode = widget.lang ?? userDeviceLanguageCode;
    _releaseCategory = ref.read(homeReleaseCategoryProvider);
    _scrollController.addListener(_onScrollPositionChanged);
    _initializeData();
    _startHeroAutoSlide();
  }

  void _onScrollPositionChanged() {
    if (!_scrollController.hasClients) return;
    final shouldShow = _scrollController.offset > _scrollToTopThreshold &&
        _movies.isNotEmpty &&
        !_isLoading;
    if (_showScrollToTop.value != shouldShow) {
      _showScrollToTop.value = shouldShow;
    }
  }

  void _startHeroAutoSlide() {
    _heroTimer?.cancel();
    _heroTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_heroCarouselController.hasClients) return;
      final nextPage = (_currentHeroPage + 1) % 5;
      _heroCarouselController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _reconnectTimer?.cancel();
    _heroCarouselController.dispose();
    _searchController.dispose();
    _scrollController.removeListener(_onScrollPositionChanged);
    _scrollController.dispose();
    _showScrollToTop.dispose();
    super.dispose();
  }

  void _startAutoReconnectIfNeeded() {
    if (_reconnectTimer?.isActive ?? false) return;
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final needsRecover = _isShowingCached ||
          _hasError ||
          _loadMoreFailureType != NetworkFailureType.none;
      if (!needsRecover) {
        timer.cancel();
        return;
      }
      if (_isCheckingReconnect || _isLoading || _isLoadingMore) return;
      _isCheckingReconnect = true;
      try {
        final online = await NetworkService.instance.hasInternet(
          forceRefresh: true,
        );
        if (online && mounted) {
          timer.cancel();
          setState(() {
            _imageRetryEpoch++;
          });
          if (_hasError || _isShowingCached) {
            _retryCurrentAction();
          } else if (_loadMoreFailureType != NetworkFailureType.none) {
            pageNum++;
            _fetchMovies(isLoadMore: true, skipOfflinePrecheck: true);
          }
        }
      } finally {
        _isCheckingReconnect = false;
      }
    });
  }

  Future<void> _initializeData() async {
    await _fetchMovies(isInitialLoad: true);
  }

  // Core supported languages for multi-language discovery when "All" is active
  static const List<String> _kAllDiscoveryLanguages = [
    'ml',
    'ta',
    'hi',
    'te',
    'en',
    'kn',
    'ko',
    'ja',
  ];

  String get _homeCacheKey =>
      'cached_movies_${_releaseCategory.name}_${_selectedLangCode ?? 'all'}';

  Future<void> _saveCachedMovies(List<dynamic> movies) async {
    if (_isSearching || _selectedGenreIds.isNotEmpty || movies.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final subset = movies.take(30).toList();
      await prefs.setString(_homeCacheKey, jsonEncode(subset));
    } catch (_) {}
  }

  Future<List<dynamic>> _loadCachedMovies() async {
    if (_isSearching || _selectedGenreIds.isNotEmpty) return const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_homeCacheKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {}
    return const [];
  }

  Future<void> _fetchMovies({
    bool isInitialLoad = false,
    bool isRefresh = false,
    bool isLoadMore = false,
    bool skipOfflinePrecheck = false,
  }) async {
    if (isLoadMore && (_isLoadingMore || !mounted)) return;

    setState(() {
      if (isInitialLoad || isRefresh) {
        _isLoading = true;
        _hasError = false;
        _isSlowConnection = false;
        _isShowingCached = false;
        _failureType = NetworkFailureType.none;
        _errorMessage = null;
        _loadMoreFailureType = NetworkFailureType.none;
        _loadMoreErrorMessage = null;
        pageNum = 1;
      }
      if (isLoadMore) {
        _isLoadingMore = true;
        _loadMoreFailureType = NetworkFailureType.none;
        _loadMoreErrorMessage = null;
      }
    });

    // Fast offline check before launching parallel TMDB calls (bypassed on explicit retry)
    if (!skipOfflinePrecheck) {
      final hasInternet = await NetworkService.instance.hasInternet(
        forceRefresh: isRefresh || isLoadMore,
      );
      if (!hasInternet) {
        if (isLoadMore && pageNum > 1) pageNum--;
        await _handleClassifiedFailure(
          const TmdbFetchException(
            type: NetworkFailureType.noInternet,
            message: 'No internet connection. Please check Wi-Fi or mobile data.',
          ),
          isLoadMore: isLoadMore,
        );
        return;
      }
    }

    Object? lastError;

    for (int attempt = 0; attempt < _maxRetryAttempts; attempt++) {
      try {
        List<dynamic> results = [];

        if (_selectedLangCode == null) {
          // "All Languages" active: fetch latest, top-rated movies across all languages in parallel
          final responses = await Future.wait(
            _kAllDiscoveryLanguages.map(
              (lang) => _fetchLanguageBatch(lang, pageNum),
            ),
          );
          results = _blendMultiLanguageMovies(responses);

          // If parallel batches were empty, fallback to generic discover
          if (results.isEmpty) {
            final fallbackUrl = _buildMovieUrl();
            final data = await NetworkService.instance.getTmdbUriJson(
              fallbackUrl,
              timeout: const Duration(seconds: 15),
              maxAttempts: 1,
              onSlowConnection: _markSlowConnection,
            );
            if (data is Map) {
              results = (data['results'] as List<dynamic>? ?? []).where((m) {
                if (m is! Map<String, dynamic>) return false;
                final poster = m['poster_path']?.toString().trim();
                return poster != null &&
                    poster.isNotEmpty &&
                    poster != 'null' &&
                    poster != 'undefined';
              }).toList();
            }
          }
        } else {
          // Single specific language selected
          final url = _buildMovieUrl();
          final data = await NetworkService.instance.getTmdbUriJson(
            url,
            timeout: const Duration(seconds: 15),
            maxAttempts: 1,
            onSlowConnection: _markSlowConnection,
          );

          if (data is Map) {
            results = (data['results'] as List<dynamic>? ?? []).where((m) {
              if (m is! Map<String, dynamic>) return false;
              final poster = m['poster_path']?.toString().trim();
              return poster != null &&
                  poster.isNotEmpty &&
                  poster != 'null' &&
                  poster != 'undefined';
            }).toList();
          }
        }

        if (!mounted) return;

        setState(() {
          if (isLoadMore) {
            final existingIds = _movies.map((m) => m['id']).toSet();
            final uniqueResults = results
                .where((m) => !existingIds.contains(m['id']))
                .toList();
            _movies.addAll(uniqueResults);
          } else {
            final seen = <dynamic>{};
            _movies = results.where((m) => seen.add(m['id'])).toList();
          }
          _isLoading = false;
          _isLoadingMore = false;
          _hasError = false;
          _isSlowConnection = false;
          _isShowingCached = false;
          _failureType = NetworkFailureType.none;
          _errorMessage = null;
        });

        if (!isLoadMore && pageNum == 1) {
          _saveCachedMovies(_movies);
        }
        return;
      } catch (e) {
        lastError = e;
        debugPrint('Movie fetch error (attempt ${attempt + 1}): $e');

        if (e is TmdbFetchException &&
            e.type == NetworkFailureType.noInternet) {
          break;
        }

        if (attempt < _maxRetryAttempts - 1) {
          _markSlowConnection();
          await Future.delayed(_retryDelay);
        }
      }
    }

    if (isLoadMore && pageNum > 1) pageNum--;
    await _handleClassifiedFailure(
      lastError ?? Exception('Failed to load movies'),
      isLoadMore: isLoadMore,
    );
  }

  void _markSlowConnection() {
    if (mounted && _isLoading && !_isSlowConnection) {
      setState(() => _isSlowConnection = true);
    }
  }

  Future<List<dynamic>> _fetchLanguageBatch(String langCode, int page) async {
    final url = _buildMovieUrl(lang: langCode, page: page);
    try {
      final data = await NetworkService.instance.getTmdbUriJson(
        url,
        timeout: const Duration(seconds: 12),
        maxAttempts: 1,
        onSlowConnection: _markSlowConnection,
      );
      if (data is Map) {
        return (data['results'] as List<dynamic>? ?? []).where((m) {
          if (m is! Map<String, dynamic>) return false;
          final poster = m['poster_path']?.toString().trim();
          return poster != null &&
              poster.isNotEmpty &&
              poster != 'null' &&
              poster != 'undefined';
        }).toList();
      }
    } catch (e) {
      debugPrint('Error fetching language batch for $langCode: $e');
      if (e is TmdbFetchException && e.type == NetworkFailureType.noInternet) {
        rethrow;
      }
    }
    return [];
  }

  List<dynamic> _blendMultiLanguageMovies(List<List<dynamic>> languageBatches) {
    final List<dynamic> blended = [];
    final Set<dynamic> seenIds = {};
    int maxLen = 0;
    for (final batch in languageBatches) {
      if (batch.length > maxLen) maxLen = batch.length;
    }

    for (int i = 0; i < maxLen; i++) {
      for (final batch in languageBatches) {
        if (i < batch.length) {
          final movie = batch[i];
          if (movie is Map<String, dynamic>) {
            final id = movie['id'];
            if (seenIds.add(id)) {
              blended.add(movie);
            }
          }
        }
      }
    }
    return blended;
  }

  Uri _buildMovieUrl({String? lang, int? page}) {
    final now = DateTime.now();
    final today = now.toIso8601String().split('T').first;
    final nextYear = now.add(const Duration(days: 365)).toIso8601String().split('T').first;
    final twoYearsAgo = now.subtract(const Duration(days: 730)).toIso8601String().split('T').first;

    final targetLang = lang ?? _selectedLangCode;
    final targetPage = page ?? pageNum;

    final langParam = (targetLang != null && targetLang.isNotEmpty)
        ? '&with_original_language=$targetLang'
        : '';
    final genreParam = _selectedGenreIds.isNotEmpty
        ? '&with_genres=${_selectedGenreIds.join(',')}'
        : '';

    String dateParam = '';
    String voteParam = '';

    if (_releaseCategory == HomeReleaseCategory.upcoming) {
      dateParam = '&primary_release_date.gte=$today&primary_release_date.lte=$nextYear';
    } else {
      // Latest releases: ensure recent release window (last 2 years) and genuine ratings
      dateParam = '&primary_release_date.gte=$twoYearsAgo&primary_release_date.lte=$today';
      voteParam = '&vote_count.gte=2';
    }

    return Uri.parse(
      'https://api.themoviedb.org/3/discover/movie'
      '?api_key=${AppConstants.apiKey}'
      '$langParam'
      '$genreParam'
      '$dateParam'
      '$voteParam'
      '&sort_by=popularity.desc'
      '&page=$targetPage',
    );
  }

  Future<void> _handleClassifiedFailure(
    Object error, {
    required bool isLoadMore,
  }) async {
    final classified = await NetworkService.instance.classifyError(error);
    if (!mounted) return;

    if (!isLoadMore && _movies.isEmpty) {
      final cached = await _loadCachedMovies();
      if (!mounted) return;
      if (cached.isNotEmpty) {
        setState(() {
          _movies = cached;
          _isLoading = false;
          _isLoadingMore = false;
          _isSlowConnection = false;
          _isShowingCached = true;
          _hasError = false;
          _failureType = classified.type;
          _errorMessage = classified.message;
        });
        _startAutoReconnectIfNeeded();
        return;
      }
    }

    final wasLoadMore = _isLoadingMore || isLoadMore;
    setState(() {
      _isLoading = false;
      _isLoadingMore = false;
      _isSlowConnection = false;
      if (wasLoadMore && _movies.isNotEmpty) {
        _loadMoreFailureType = classified.type;
        _loadMoreErrorMessage = classified.message;
      } else {
        _failureType = classified.type;
        _errorMessage = classified.message;
        _hasError = _movies.isEmpty;
      }
    });
    _startAutoReconnectIfNeeded();

    if (!wasLoadMore && _movies.isNotEmpty) {
      _showMessage(classified.message);
    }
  }

  void _retryCurrentAction() {
    if (_isSearching && _searchController.text.trim().isNotEmpty) {
      _searchMovies(_searchController.text);
    } else {
      _fetchMovies(isRefresh: true, skipOfflinePrecheck: true);
    }
  }

  Future<void> _searchMovies(String query) async {
    final trimmedQuery = query.trim();

    if (trimmedQuery.isEmpty) {
      _onRefresh();
      return;
    }

    if (!mounted) return;
    _showScrollToTop.value = false;
    setState(() {
      _isLoading = true;
      _hasError = false;
      _isSlowConnection = false;
      _isShowingCached = false;
      _failureType = NetworkFailureType.none;
      _errorMessage = null;
      _isSearching = true;
    });

    final url = Uri.parse(
      'https://api.themoviedb.org/3/search/movie'
      '?api_key=${AppConstants.apiKey}'
      '&query=${Uri.encodeComponent(trimmedQuery)}',
    );

    try {
      final data = await NetworkService.instance.getTmdbUriJson(
        url,
        timeout: const Duration(seconds: 15),
        maxAttempts: 2,
        onSlowConnection: _markSlowConnection,
      );
      if (!mounted) return;
      final results = (data is Map ? data['results'] : null) as List<dynamic>? ?? [];
      setState(() {
        _movies = results;
        pageNum = 1;
        _isLoading = false;
        _isSlowConnection = false;
        _hasError = false;
        _scrollToTop(animate: false);
      });
    } catch (e) {
      final classified = await NetworkService.instance.classifyError(e);
      if (!mounted) return;
      setState(() {
        _movies = [];
        _isLoading = false;
        _isSlowConnection = false;
        _hasError = true;
        _failureType = classified.type;
        _errorMessage = classified.message;
      });
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
    userDeviceLanguageCode = code;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('user_manual_selection', true);
      if (code != null) {
        prefs.setString('selected_language', code);
        prefs.setBool('selected_language_cleared', false);
      } else {
        prefs.remove('selected_language');
        prefs.setBool('selected_language_cleared', true);
      }
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
    final isNearBottom =
        notification.metrics.pixels >=
        notification.metrics.maxScrollExtent - _loadMoreThreshold;
    if (isNearBottom &&
        !_isLoadingMore &&
        !_isLoading &&
        !_isSearching &&
        _movies.isNotEmpty &&
        _loadMoreFailureType == NetworkFailureType.none) {
      pageNum++;
      _fetchMovies(isLoadMore: true);
    }
    return true;
  }

  Future<void> _onRefresh() async {
    if (_isSearching && _searchController.text.trim().isNotEmpty) {
      await _searchMovies(_searchController.text);
      return;
    }
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
    final favProvider = p.Provider.of<FavoritesProvider>(context);
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
        floatingActionButton: null,
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
        body: Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: RefreshIndicator(
                      onRefresh: _onRefresh,
                      color: Colors.green,
                      backgroundColor: Colors.grey.shade900,
                      child: CustomScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          // 1. Search Bar
                          SliverToBoxAdapter(child: _buildSearchBar()),

                          // 1a. Slow Internet / Offline Cache Banner
                          if (_isSlowConnection && _isLoading)
                            const SliverToBoxAdapter(
                              child: NetworkStatusBanner(
                                isSlow: true,
                                message:
                                    'Slow connection detected — still loading movies...',
                              ),
                            )
                          else if (_isShowingCached && !_isLoading)
                            SliverToBoxAdapter(
                              child: NetworkStatusBanner(
                                isOffline: _failureType ==
                                    NetworkFailureType.noInternet,
                                isSlow: _failureType ==
                                    NetworkFailureType.slowOrTimeout,
                                message: _failureType ==
                                        NetworkFailureType.noInternet
                                    ? 'No internet — showing saved movies'
                                    : 'Slow connection — showing saved movies',
                                onRetry: _retryCurrentAction,
                              ),
                            ),

                          // 1b. Trending Hero Carousel (when not searching)
                          if (!_isSearching && !(_hasError && _movies.isEmpty))
                            SliverToBoxAdapter(
                              child: _movies.length >= 3
                                  ? _buildTrendingHeroCarousel()
                                  : (_isLoading
                                      ? _buildHeroCarouselShimmer()
                                      : const SizedBox.shrink()),
                            ),

                          // 2. Section Header with Language and Genre filter badges
                          SliverToBoxAdapter(child: _buildSectionHeader()),

                          // 4. Grid View / Loading / Offline / Empty State
                          _isLoading
                              ? SliverToBoxAdapter(child: _buildShimmerLoading())
                              : (_hasError && _movies.isEmpty
                                  ? SliverFillRemaining(
                                      hasScrollBody: false,
                                      child: NetworkStateView(
                                        failureType: _failureType,
                                        customMessage: _errorMessage,
                                        onRetry: _retryCurrentAction,
                                      ),
                                    )
                                  : (_movies.isEmpty
                                      ? SliverToBoxAdapter(
                                          child: _buildEmptyState(),
                                        )
                                      : SliverPadding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: wt * 0.04,
                                        ),
                                        sliver: SliverGrid(
                                          gridDelegate:
                                              SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: 2,
                                                mainAxisSpacing: wt * 0.04,
                                                crossAxisSpacing: wt * 0.035,
                                                mainAxisExtent: wt * 0.78,
                                              ),
                                          delegate: SliverChildBuilderDelegate((
                                            context,
                                            index,
                                          ) {
                                            final movie = _movies[index]
                                                as Map<String, dynamic>;
                                            final genres = _getMovieGenres(movie);
                                            final subtitle =
                                                _getMovieSubtitle(movie, genres);

                                            return _MovieCard(
                                              movie: movie,
                                              genres: genres,
                                              subtitle: subtitle,
                                              imageRetryEpoch: _imageRetryEpoch,
                                              isLiked:
                                                  favProvider.isLiked(movie['id']),
                                              isLiking: favProvider.isMovieLoading(
                                                movie['id'],
                                              ),
                                              onTap: () =>
                                                  _navigateToPreview(movie),
                                                onFavorite: () async {
                                                  try {
                                                    await favProvider.toggleFavorite(
                                                      movieId: movie['id'],
                                                      title: movie['title'] ??
                                                          movie['name'] ??
                                                          '',
                                                      posterPath:
                                                          movie['poster_path'],
                                                      backdropPath:
                                                          movie['backdrop_path'],
                                                      releaseDate:
                                                          movie['release_date'],
                                                      rating:
                                                          (movie['vote_average'] ??
                                                                  0)
                                                              .toDouble(),
                                                    );
                                                  } catch (_) {
                                                    _showMessage(
                                                      'Could not update favorite. Check your internet connection.',
                                                    );
                                                  }
                                                },
                                              );
                                            }, childCount: _movies.length),
                                          ),
                                        ))),

                          // 6. Pagination Loader / Offline Footer
                          if (_isLoadingMore)
                            SliverToBoxAdapter(child: _buildLoadingMoreIndicator())
                          else if (_loadMoreFailureType !=
                              NetworkFailureType.none)
                            SliverToBoxAdapter(
                              child: _buildLoadMoreErrorFooter(),
                            ),

                          // Bottom padding
                          SliverToBoxAdapter(child: SizedBox(height: ht * 0.12)),
                        ],
                      ),
                    ),
                  ),

                  // Floating Scroll-To-Top button
                  Positioned(
                    right: 16,
                    bottom: 102,
                    child: _buildScrollToTopButton(),
                  ),
                ],
              ),
      ),
    );
  }

  // ── Modern Floating Scroll-To-Top Button ───────────────────────────────────
  Widget _buildScrollToTopButton() {
    final bool isUpcoming = _releaseCategory == HomeReleaseCategory.upcoming;
    final Color themeAccent =
        isUpcoming ? const Color(0xFFFF9F1C) : const Color(0xFF00E5A0);

    return ValueListenableBuilder<bool>(
      valueListenable: _showScrollToTop,
      builder: (context, visible, _) {
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.35),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: Tooltip(
                message: 'Back to top',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _showScrollToTop.value = false;
                      _scrollToTop(animate: true);
                    },
                    borderRadius: BorderRadius.circular(23),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xFF151926).withValues(alpha: 0.94),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: themeAccent.withValues(alpha: 0.4),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.55),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: themeAccent.withValues(alpha: 0.14),
                            blurRadius: 14,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        color: themeAccent,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Surprise Me Button (Stacked Card Style) ────────────────────────────────
  Widget _buildSurpriseMeButton() {
    return Tooltip(
      message: 'Surprise Me with a top movie',
      child: GestureDetector(
        onTap: _pickSurpriseMovie,
        child: SizedBox(
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Under-layer: tilted/offset stacked card backdrop
              Positioned(
                left: 2,
                top: 2,
                right: -2,
                bottom: -2,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF9F1C).withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFFF9F1C).withValues(alpha: 0.38),
                      width: 1,
                    ),
                  ),
                ),
              ),
              // Front primary button
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF1E2332),
                      Color(0xFF121520),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFF9F1C).withValues(alpha: 0.55),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.style_rounded,
                        color: Color(0xFFFF9F1C),
                        size: 15,
                      ),
                      SizedBox(width: 5),
                      Text(
                        'Surprise Me',
                        style: TextStyle(
                          color: Color(0xFFFF9F1C),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
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

  // ── Search Bar ─────────────────────────────────────────────────────────────
  Widget _buildSearchBar() {
    final bool isUpcoming = _releaseCategory == HomeReleaseCategory.upcoming;
    final Color themeAccent =
        isUpcoming ? const Color(0xFFFF9F1C) : const Color(0xFF00E676);

    return Padding(
      padding:
          EdgeInsets.fromLTRB(wt * 0.04, wt * 0.015, wt * 0.04, wt * 0.02),
      child: Row(
        children: [
          Expanded(
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
          ),
          if (!_isSearching && _movies.isNotEmpty) ...[
            const SizedBox(width: 8),
            _buildSurpriseMeButton(),
          ],
        ],
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
          Flexible(
            child: Text(
              _isSearching
                  ? 'Search Results'
                  : (_releaseCategory == HomeReleaseCategory.upcoming
                      ? 'Upcoming'
                      : 'Discover'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: wt * 0.043,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (!_isSearching) ...[
            const Spacer(),
            // Genre Filter Badge
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _showGenreBottomSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
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
                      constraints: const BoxConstraints(maxWidth: 54),
                      child: Text(
                        genreLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _selectedGenreIds.isNotEmpty
                              ? Colors.green
                              : Colors.white,
                          fontSize: wt * 0.026,
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
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 5),
            // Language Filter Badge
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _showLanguageBottomSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
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
                      style: const TextStyle(fontSize: 11),
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 46),
                      child: Text(
                        currentLang['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _selectedLangCode != null
                              ? Colors.green
                              : Colors.white,
                          fontSize: wt * 0.026,
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
                      size: 14,
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

  void _pickSurpriseMovie() {
    HapticFeedback.lightImpact();

    String? tempLang = _selectedLangCode;
    final Set<int> tempGenres = Set<int>.from(_selectedGenreIds);
    double tempMinRating = 6.0;
    bool isSpinning = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF14171F),
      barrierColor: Colors.black.withValues(alpha: 0.7),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            Future<void> launchRoulette() async {
              if (isSpinning) return;
              setSheetState(() => isSpinning = true);
              HapticFeedback.heavyImpact();

              List<Map<String, dynamic>> pool = [];

              // Try fetching fresh filtered candidates from TMDB if online
              if (await NetworkService.instance.hasInternet()) {
                try {
                  final randomPage = Random().nextInt(4) + 1;
                  final now = DateTime.now();
                  final today = now.toIso8601String().split('T').first;
                  final twoYearsAgo = now
                      .subtract(const Duration(days: 730))
                      .toIso8601String()
                      .split('T')
                      .first;
                  final nextYear = now
                      .add(const Duration(days: 365))
                      .toIso8601String()
                      .split('T')
                      .first;

                  final langQ = (tempLang != null && tempLang!.isNotEmpty)
                      ? '&with_original_language=$tempLang'
                      : '';
                  final genreQ = tempGenres.isNotEmpty
                      ? '&with_genres=${tempGenres.join(',')}'
                      : '';
                  final dateQ =
                      _releaseCategory == HomeReleaseCategory.upcoming
                          ? '&primary_release_date.gte=$today&primary_release_date.lte=$nextYear'
                          : '&primary_release_date.gte=$twoYearsAgo&primary_release_date.lte=$today';
                  final voteQ = tempMinRating > 0
                      ? '&vote_average.gte=$tempMinRating&vote_count.gte=5'
                      : '';

                  final res = await NetworkService.instance.getTmdbJson(
                    '/3/discover/movie?api_key=${AppConstants.apiKey}$langQ$genreQ$dateQ$voteQ&sort_by=popularity.desc&page=$randomPage',
                    timeout: const Duration(seconds: 8),
                    maxAttempts: 1,
                  );
                  if (res is Map && res['results'] is List) {
                    pool = (res['results'] as List)
                        .whereType<Map>()
                        .map((e) => Map<String, dynamic>.from(e))
                        .where((m) {
                      final poster = m['poster_path']?.toString().trim();
                      return poster != null &&
                          poster.isNotEmpty &&
                          poster != 'null';
                    }).toList();
                  }
                } catch (_) {}
              }

              // Fallback to local loaded movies filtered by criteria
              if (pool.isEmpty) {
                pool = _movies
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((m) {
                  final poster = m['poster_path']?.toString().trim();
                  if (poster == null || poster.isEmpty || poster == 'null') {
                    return false;
                  }
                  if (tempLang != null &&
                      (m['original_language']?.toString() ?? '') != tempLang) {
                    return false;
                  }
                  if (tempGenres.isNotEmpty) {
                    final ids = (m['genre_ids'] as List? ?? []).toSet();
                    if (!tempGenres.any(ids.contains)) return false;
                  }
                  final vote = (m['vote_average'] is num)
                      ? (m['vote_average'] as num).toDouble()
                      : 0.0;
                  return vote >= tempMinRating;
                }).toList();
              }

              // Final fallback to any movie with a poster
              if (pool.isEmpty) {
                pool = _movies
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((m) {
                  final poster = m['poster_path']?.toString().trim();
                  return poster != null &&
                      poster.isNotEmpty &&
                      poster != 'null';
                }).toList();
              }

              if (!mounted) return;
              if (ctx.mounted) Navigator.pop(ctx);

              if (pool.isEmpty) {
                _showMessage('No movies available to pick from right now.');
                return;
              }

              final pickedMovie = pool[Random().nextInt(pool.length)];
              final genres = _getMovieGenres(pickedMovie);
              final subtitle = _getMovieSubtitle(pickedMovie, genres);

              Navigator.push(
                context,
                PageRouteBuilder(
                  transitionDuration: const Duration(milliseconds: 320),
                  pageBuilder: (context, animation, secondaryAnimation) {
                    return RandomMoviePickerPage(
                      pickedMovie: pickedMovie,
                      subtitle: subtitle,
                      candidateMovies: pool,
                    );
                  },
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
                child: SingleChildScrollView(
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
                      const SizedBox(height: 16),
                      const Row(
                        children: [
                          Icon(
                            Icons.style_rounded,
                            color: Color(0xFFFF9F1C),
                            size: 22,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Surprise Me Roulette',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Filter your mood or spin right away for a random pick.',
                        style: TextStyle(color: Colors.white54, fontSize: 12.5),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Minimum Rating',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [0.0, 6.0, 7.0, 8.0].map((r) {
                          final selected = tempMinRating == r;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setSheetState(() => tempMinRating = r);
                              },
                              child: Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFFFF9F1C)
                                          .withValues(alpha: 0.18)
                                      : const Color(0xFF191D26),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: selected
                                        ? const Color(0xFFFF9F1C)
                                        : Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    r == 0.0 ? 'Any' : '${r.toInt()}.0+ ★',
                                    style: TextStyle(
                                      color: selected
                                          ? const Color(0xFFFF9F1C)
                                          : Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Language',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _languages.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (_, idx) {
                            final lang = _languages[idx];
                            final code = lang['code'] as String?;
                            final selected = tempLang == code;
                            return InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setSheetState(() => tempLang = code);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFF00E5A0)
                                          .withValues(alpha: 0.16)
                                      : const Color(0xFF191D26),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: selected
                                        ? const Color(0xFF00E5A0)
                                        : Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(lang['flag'] as String? ?? '🌐'),
                                    const SizedBox(width: 5),
                                    Text(
                                      lang['name'] as String,
                                      style: TextStyle(
                                        color: selected
                                            ? const Color(0xFF00E5A0)
                                            : Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Genres (Optional)',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: _genres.take(10).map((g) {
                          final gid = g['id'] as int;
                          final selected = tempGenres.contains(gid);
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setSheetState(() {
                                if (selected) {
                                  tempGenres.remove(gid);
                                } else {
                                  tempGenres.add(gid);
                                }
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? const Color(0xFFFF9F1C)
                                        .withValues(alpha: 0.16)
                                    : const Color(0xFF191D26),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: selected
                                      ? const Color(0xFFFF9F1C)
                                      : Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Text(
                                g['name'] as String,
                                style: TextStyle(
                                  color: selected
                                      ? const Color(0xFFFF9F1C)
                                      : Colors.white70,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: isSpinning ? null : launchRoulette,
                          icon: isSpinning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Icon(Icons.casino_rounded, size: 19),
                          label: Text(
                            isSpinning
                                ? 'Finding Matching Movies...'
                                : 'Spin Roulette',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14.5,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF9F1C),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTrendingHeroCarousel() {
    final heroMovies = _movies
        .where((m) =>
            m['backdrop_path'] != null &&
            m['backdrop_path'].toString().isNotEmpty)
        .take(5)
        .toList();

    if (heroMovies.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.fromLTRB(
        wt * 0.04,
        wt * 0.01,
        wt * 0.04,
        wt * 0.03,
      ),
      child: Column(
        children: [
          SizedBox(
            height: wt * 0.48,
            child: PageView.builder(
              controller: _heroCarouselController,
              itemCount: heroMovies.length,
              onPageChanged: (idx) {
                setState(() => _currentHeroPage = idx);
              },
              itemBuilder: (context, index) {
                final movie = heroMovies[index] as Map<String, dynamic>;
                final title =
                    (movie['title'] ?? movie['name'] ?? 'Movie').toString();
                final backdrop = movie['backdrop_path']?.toString() ?? '';
                final poster = movie['poster_path']?.toString();
                final rating = (movie['vote_average'] ?? 0.0);
                final ratingStr =
                    rating is num ? rating.toStringAsFixed(1) : rating.toString();
                final genres = _getMovieGenres(movie);
                final subtitle = _getMovieSubtitle(movie, genres);

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MoviePreview(
                          movieId: movie['id'],
                          initialMovie: movie,
                          posterPath: poster,
                          title: title,
                          backdropPath: backdrop,
                          subtitle: subtitle,
                          heroTag: 'hero_carousel_${movie['id']}',
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Backdrop image
                          CachedNetworkImage(
                            key: ValueKey(
                              'hero_backdrop_${movie['id']}_$_imageRetryEpoch',
                            ),
                            imageUrl: '${AppConstants.baseImageUrl}$backdrop',
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Shimmer.fromColors(
                              baseColor: const Color(0xFF161922),
                              highlightColor: const Color(0xFF222634),
                              child: Container(color: const Color(0xFF161922)),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: const Color(0xFF161922),
                              child: const Icon(
                                Icons.movie_rounded,
                                color: Colors.white24,
                                size: 40,
                              ),
                            ),
                          ),
                          // Gradient fade
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.3),
                                  Colors.black.withValues(alpha: 0.92),
                                ],
                                stops: const [0.3, 0.6, 1.0],
                              ),
                            ),
                          ),
                          // Content details
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: 12,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF00E5A0)
                                                  .withValues(alpha: 0.2),
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              border: Border.all(
                                                color: const Color(0xFF00E5A0)
                                                    .withValues(alpha: 0.4),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: const Text(
                                              'FEATURED',
                                              style: TextStyle(
                                                color: Color(0xFF00E5A0),
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.4,
                                              ),
                                            ),
                                          ),
                                          if (ratingStr != '0' &&
                                              ratingStr != '0.0') ...[
                                            const SizedBox(width: 6),
                                            Row(
                                              children: [
                                                const Icon(
                                                  Icons.star_rounded,
                                                  color: Colors.amber,
                                                  size: 14,
                                                ),
                                                const SizedBox(width: 2),
                                                Text(
                                                  ratingStr,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                      if (subtitle.isNotEmpty)
                                        Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.7),
                                            fontSize: 11.5,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.all(9),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00E5A0),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF00E5A0)
                                            .withValues(alpha: 0.4),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.black,
                                    size: 20,
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
          const SizedBox(height: 8),
          // Dot indicators
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              heroMovies.length,
              (idx) => AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: _currentHeroPage == idx ? 16 : 5,
                height: 4,
                decoration: BoxDecoration(
                  color: _currentHeroPage == idx
                      ? const Color(0xFF00E5A0)
                      : Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
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

  Widget _buildHeroCarouselShimmer() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        wt * 0.04,
        wt * 0.01,
        wt * 0.04,
        wt * 0.03,
      ),
      child: Shimmer.fromColors(
        baseColor: const Color(0xFF131722),
        highlightColor: const Color(0xFF232A3B),
        period: const Duration(milliseconds: 1300),
        child: Container(
          height: wt * 0.48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF131722),
      highlightColor: const Color(0xFF232A3B),
      period: const Duration(milliseconds: 1300),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: wt * 0.04),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 6,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: wt * 0.04,
            crossAxisSpacing: wt * 0.035,
            mainAxisExtent: wt * 0.78,
          ),
          itemBuilder: (context, index) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Poster box matching _MovieCard
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Stack(
                      children: [
                        // Top-left rating badge placeholder
                        Positioned(
                          top: 7,
                          left: 7,
                          child: Container(
                            width: 38,
                            height: 18,
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                        // Top-right favorite button placeholder
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: const BoxDecoration(
                              color: Colors.black26,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                // Title placeholder
                Container(
                  height: 14,
                  width: wt * 0.34,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 5),
                // Subtitle / Genres placeholder
                Container(
                  height: 10,
                  width: wt * 0.22,
                  decoration: BoxDecoration(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            );
          },
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

  Widget _buildLoadMoreErrorFooter() {
    final bool isOffline = _loadMoreFailureType == NetworkFailureType.noInternet;
    final bool isSlow = _loadMoreFailureType == NetworkFailureType.slowOrTimeout;
    final Color accent = isOffline
        ? const Color(0xFFFF6B6B)
        : (isSlow ? const Color(0xFFFF9F1C) : const Color(0xFF00E5A0));

    return Padding(
      // Leave right clearance so the floating scroll-to-top button never overlaps
      padding: const EdgeInsets.fromLTRB(20, 14, 72, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.35), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  isOffline
                      ? Icons.wifi_off_rounded
                      : (isSlow
                          ? Icons.hourglass_bottom_rounded
                          : Icons.cloud_off_rounded),
                  color: accent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isOffline
                        ? 'No internet connection'
                        : (isSlow
                            ? 'Slow connection — could not load more'
                            : (_loadMoreErrorMessage ??
                                'Could not load more movies')),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  pageNum++;
                  _fetchMovies(
                    isLoadMore: true,
                    skipOfflinePrecheck: true,
                  );
                },
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text(
                  'Retry Loading More',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: const Color(0xFF0B0E16),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _getMovieGenres(Map<String, dynamic> movie) {
    if (movie['genres'] is List) {
      return (movie['genres'] as List)
          .map((g) => g is Map ? (g['name']?.toString() ?? '') : g.toString())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    final genreIds = movie['genre_ids'] as List<dynamic>? ?? [];
    final List<String> names = [];
    for (final id in genreIds) {
      final matched = _genres.firstWhere(
        (g) => g['id'] == id,
        orElse: () => <String, dynamic>{},
      );
      if (matched.isNotEmpty && matched['name'] != null) {
        names.add(matched['name'] as String);
      }
    }
    return names;
  }

  String _getMovieSubtitle(Map<String, dynamic> movie, List<String> genres) {
    final releaseDate = (movie['release_date'] ?? '').toString();
    String dateOrYear =
        releaseDate.contains('-') ? releaseDate.split('-').first : releaseDate;

    if (releaseDate.isNotEmpty) {
      try {
        final parsedDate = DateTime.tryParse(releaseDate);
        if (parsedDate != null && parsedDate.isAfter(DateTime.now())) {
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
          dateOrYear =
              '${months[parsedDate.month - 1]} ${parsedDate.day}, ${parsedDate.year}';
        }
      } catch (_) {}
    }

    final genreText = genres.take(2).join(', ');
    if (genreText.isNotEmpty && dateOrYear.isNotEmpty) {
      return '$genreText • $dateOrYear';
    } else if (genreText.isNotEmpty) {
      return genreText;
    } else if (dateOrYear.isNotEmpty) {
      return dateOrYear;
    }
    return '';
  }

  void _navigateToPreview(dynamic movieData) {
    final Map<String, dynamic>? movie = (movieData is Map<String, dynamic>)
        ? movieData
        : null;
    final String movieId = movie != null
        ? movie['id'].toString()
        : movieData.toString();

    final List<String> genres = movie != null ? _getMovieGenres(movie) : [];
    final String subtitle =
        movie != null ? _getMovieSubtitle(movie, genres) : '';

    // Pass only authentic data from TMDB (do not inject synthetic 'tagline' or fake 'status')
    final Map<String, dynamic>? enrichedMovie = movie != null
        ? {
            ...movie,
          }
        : null;

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (context, animation, secondaryAnimation) {
          return MoviePreview(
            movieId: movieId,
            initialMovie: enrichedMovie,
            posterPath: movie?['poster_path'],
            title: movie?['title'] ?? movie?['name'],
            backdropPath: movie?['backdrop_path'],
            initialGenres: null,
            subtitle: subtitle,
            heroTag: 'movie_hero_$movieId',
            titleHeroTag: 'movie_title_$movieId',
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
  final List<String> genres;
  final String subtitle;
  final int imageRetryEpoch;
  final bool isLiked;
  final bool isLiking;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  const _MovieCard({
    required this.movie,
    required this.genres,
    required this.subtitle,
    this.imageRetryEpoch = 0,
    required this.isLiked,
    required this.isLiking,
    required this.onTap,
    required this.onFavorite,
  });

  Widget _buildPosterFlightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final Widget toHeroWidget = (toHeroContext.widget is Hero)
        ? (toHeroContext.widget as Hero).child
        : toHeroContext.widget;

    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: toHeroWidget,
      ),
    );
  }

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
            fit: StackFit.passthrough,
            alignment: Alignment.centerLeft,
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
    final voteAverage = (movie['vote_average'] ?? 0).toDouble();

    final releaseDate = (movie['release_date'] ?? '').toString();
    bool isUpcoming = false;
    String upcomingBadgeText = '';
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
          upcomingBadgeText =
              '${months[parsedDate.month - 1]} ${parsedDate.day}';
        }
      } catch (_) {}
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 1. Poster Container ──
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Poster Hero
                  Hero(
                    tag: 'movie_hero_${movie['id']}',
                    createRectTween: (begin, end) =>
                        MaterialRectCenterArcTween(begin: begin, end: end),
                    flightShuttleBuilder: _buildPosterFlightShuttle,
                    child: Material(
                      type: MaterialType.transparency,
                      child: posterPath != null
                          ? CachedNetworkImage(
                              key: ValueKey(
                                'home_poster_${movie['id']}_$imageRetryEpoch',
                              ),
                              imageUrl:
                                  'https://image.tmdb.org/t/p/w500$posterPath',
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Container(
                                color: const Color(0xFF1B1F2A),
                                child: Center(
                                  child: LoadingAnimationWidget.fallingDot(
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                ),
                              ),
                              errorWidget: (context, url, error) =>
                                  _buildErrorImage(),
                            )
                          : _buildErrorImage(),
                    ),
                  ),

                  // Rating Badge or Upcoming Badge (Top-Left)
                  if (isUpcoming && upcomingBadgeText.isNotEmpty)
                    Positioned(
                      top: 7,
                      left: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color:
                                const Color(0xFFFF9F1C).withValues(alpha: 0.6),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.hourglass_top_rounded,
                              color: Color(0xFFFF9F1C),
                              size: 10,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              upcomingBadgeText,
                              style: const TextStyle(
                                color: Color(0xFFFF9F1C),
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (voteAverage > 0)
                    Positioned(
                      top: 7,
                      left: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.amber.withValues(alpha: 0.4),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star_rounded,
                              color: Colors.amber,
                              size: 12,
                            ),
                            const SizedBox(width: 2.5),
                            Text(
                              voteAverage.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Favorite Button (Top-Right)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        onFavorite();
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: isLiking
                              ? LoadingAnimationWidget.fallingDot(
                                  color: Colors.red,
                                  size: 14,
                                )
                              : Icon(
                                  isLiked
                                      ? Amicons.iconly_heart_fill
                                      : Amicons.iconly_heart,
                                  color: isLiked ? Colors.red : Colors.white,
                                  size: 15,
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 2. Movie Name & Info Below Poster ──
          const SizedBox(height: 7),
          Hero(
            tag: 'movie_title_${movie['id']}',
            createRectTween: (begin, end) =>
                MaterialRectCenterArcTween(begin: begin, end: end),
            flightShuttleBuilder: _buildTitleFlightShuttle,
            child: Material(
              type: MaterialType.transparency,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isUpcoming ? const Color(0xFFFF9F1C) : Colors.white54,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorImage() {
    return Container(
      color: const Color(0xFF1B1F2A),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.movie_outlined, color: Colors.grey.shade600, size: 28),
            const SizedBox(height: 4),
            Text(
              'No Poster',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
