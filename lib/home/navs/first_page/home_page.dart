import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rating/flutter_rating.dart';
import 'package:http/http.dart' as http;
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/models/movie_model.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import '../../../main.dart';
import '../../../provider/client.dart';
import '../../../splash.dart';

class HomePage extends StatefulWidget {
  final String lang;
  const HomePage({super.key, this.lang = 'en'});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // State variables
  bool _showFAB = false;
  bool _isLoading = false;
  bool _isLoadingTrending = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  bool _isSearching = false;
  double _scrollPixel = 0;

  // Language settings
  String _selectedLangCode = 'en';
  final List<Map<String, String>> _languages = [
    {'code': 'en', 'name': 'English'},
    {'code': 'ml', 'name': 'Malayalam'},
    {'code': 'ta', 'name': 'Tamil'},
    {'code': 'hi', 'name': 'Hindi'},
    {'code': 'kn', 'name': 'Kannada'},
    {'code': 'ja', 'name': 'Japanese'},
    {'code': 'de', 'name': 'German'},
    {'code': 'ko', 'name': 'Korean'},
    {'code': 'pt', 'name': 'Portuguese'},
  ];

  // Data
  List<dynamic> _movies = [];
  List<dynamic> _trendingMovies = [];
  List<int> _likedMovieIds = [];
  Set<int> _likingInProgress = {};

  // Controllers
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final PageController _trendingController = PageController(viewportFraction: 0.85);

  // Device info
  String _deviceId = '';

  // Constants
  static const int _maxRetryAttempts = 3;
  static const Duration _retryDelay = Duration(seconds: 1);
  static const double _fabShowThreshold = 1000;
  static const double _loadMoreThreshold = 100;

  @override
  void initState() {
    super.initState();
    _selectedLangCode = widget.lang;
    _initializeData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _trendingController.dispose();
    super.dispose();
  }

  Future<void> _initializeData() async {
    _deviceId = Provider.of<ClientProvider>(context, listen: false).clientId ?? '';
    await Future.wait([
      _fetchMovies(isInitialLoad: true),
      _fetchLikedMovies(),
    ]);
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
        final response = await http.get(url).timeout(
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
    return Uri.parse(
      'https://api.themoviedb.org/3/discover/movie'
          '?api_key=${AppConstants.apiKey}'
          '&with_original_language=$_selectedLangCode'
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
      // If cleared, go back to discover mode
      _onRefresh();
      return;
    }

    if (!mounted) return;
    setState(() {
      _showFAB = false;
      _isLoading = true;
      _hasError = false;
      _isSearching = true; // Hide trending/tabs
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

  void _onLanguageChange(String code) {
    if (_selectedLangCode == code) return;
    setState(() {
      _selectedLangCode = code;
      _movies.clear();
      _trendingMovies.clear();
      _isSearching = false;
      _searchController.clear();
    });
    // Re-fetch everything with new language
    Future.wait([
      _fetchMovies(isInitialLoad: true),
    ]);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showScaffoldMsg(context, txt: message);
  }

  void _scrollToTop({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    if (animate) {
      _scrollController.animateTo(0, duration: const Duration(milliseconds: 500), curve: Curves.fastEaseInToSlowEaseOut);
    } else {
      _scrollController.jumpTo(0);
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _scrollPixel = notification.metrics.pixels;

    // Show/hide FAB
    final shouldShowFAB = _scrollPixel > _fabShowThreshold;
    if (shouldShowFAB != _showFAB && mounted) {
      setState(() => _showFAB = shouldShowFAB);
    }

    // Load more
    final isNearBottom = _scrollPixel >= notification.metrics.maxScrollExtent - _loadMoreThreshold;
    if (isNearBottom && !_isLoadingMore && !_isLoading && !_isSearching) {
      pageNum++;
      _fetchMovies(isLoadMore: true).catchError((_) {
        pageNum--; // rollback on error
      });
    }
    return true;
  }

  Future<void> _onRefresh() async {
    setState(() {
      _isSearching = false;
      _searchController.clear();
    });
    await Future.wait([
      _fetchMovies(isRefresh: true),
    ]);
    _scrollToTop(animate: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      floatingActionButton: _showFAB
          ? Padding(
        padding: EdgeInsets.symmetric(vertical: wt * 0.03, horizontal: wt * 0.01),
        child: FloatingActionButton(
          onPressed: _scrollToTop,
          backgroundColor: Colors.white70,
          child: const Icon(Icons.arrow_upward, color: Colors.black),
        ),
      )
          : null,
      appBar: AppBar(
        title: const Text('MRDb'),
        titleTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: wt * 0.06),
        backgroundColor: Colors.black,
        leading: Icon(Icons.menu, color: Colors.white, size: wt * 0.08),
        actions: [
          Icon(Icons.movie_creation_outlined, color: Colors.white, size: wt * 0.08),
          SizedBox(width: wt * 0.03),
        ],
      ),
      body: _hasError
          ? Center(
        child: InkWell(
          borderRadius: BorderRadius.circular(wt * 0.1),
          onTap: () {
            _initializeData();
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: wt * 0.05, vertical: wt * 0.025),
            decoration: BoxDecoration(color: Colors.grey.shade700, borderRadius: BorderRadius.circular(wt * 0.1)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Amicons.vuesax_refresh_circle_fill, size: wt * 0.07, color: Colors.white54),
                SizedBox(width: wt * 0.02),
                const Text('Retry', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
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
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(wt * 0.04, wt * 0.02, wt * 0.04, wt * 0.02),
                  child: TextFormField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onFieldSubmitted: _searchMovies,
                    cursorColor: Colors.white,
                    cursorHeight: ht * 0.025,
                    style: TextStyle(color: Colors.grey.shade300, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      fillColor: Colors.grey.shade700,
                      filled: true,
                      hintText: 'Search movies...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      prefixIcon: const Icon(Icons.search, color: Colors.grey),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          _onRefresh(); // Reset to discover
                        },
                      )
                          : null,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(wt * 0.04)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(wt * 0.04),
                        borderSide: BorderSide(color: Colors.white, width: wt * 0.006),
                      ),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(wt * 0.04)),
                    ),
                  ),
                ),
              ),

              // 2. Language Tabs (Hidden during search)
              if (!_isSearching)
                SliverToBoxAdapter(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: wt * 0.04),
                    child: Row(
                      children: _languages.map((lang) {
                        final isSelected = _selectedLangCode == lang['code'];
                        return Padding(
                          padding: EdgeInsets.only(right: wt * 0.02),
                          child: ChoiceChip(
                            label: Text(lang['name']!),
                            selected: isSelected,
                            onSelected: (_) => _onLanguageChange(lang['code']!),
                            selectedColor: Colors.green,
                            backgroundColor: Colors.grey.shade800,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.grey.shade400,
                              fontWeight: FontWeight.bold,
                            ),
                            side: BorderSide.none,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(wt * 0.04, wt * 0.04, wt * 0.04, wt * 0.02),
                  child: Text(
                    _isSearching ? "Search Results" : "Discover Movies",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: wt * 0.05,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              _isLoading
                  ? SliverToBoxAdapter(child: _buildShimmerLoading())
                  : (_movies.isEmpty
                  ? SliverToBoxAdapter(child: _buildEmptyState())
                  : SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: wt * 0.04),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: ht * 0.02,
                    crossAxisSpacing: wt * 0.04,
                    mainAxisExtent: wt * 0.9,
                  ),
                  delegate: SliverChildBuilderDelegate(
                        (context, index) {
                      return _MovieCard(
                        movie: _movies[index],
                        isLiked: _likedMovieIds.contains(_movies[index]['id']),
                        isLiking: _likingInProgress.contains(_movies[index]['id']),
                        onTap: () => _navigateToPreview(_movies[index]['id']),
                        onFavorite: () => _addToFavorites(
                          movieId: _movies[index]['id'],
                          title: _movies[index]['title'] ?? '',
                          posterPath: _movies[index]['poster_path'],
                          releaseDate: _movies[index]['release_date'],
                          rating: (_movies[index]['vote_average'] ?? 0).toDouble(),
                        ),
                      );
                    },
                    childCount: _movies.length,
                  ),
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
    );
  }



  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: ht * 0.05),
          Icon(Amicons.iconly_video, size: wt * 0.2, color: Colors.grey.shade600),
          SizedBox(height: ht * 0.02),
          Text(
            'No movies found',
            style: TextStyle(color: Colors.grey.shade500, fontSize: wt * 0.045),
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
        colors: [Colors.grey.shade800, Colors.grey.shade600, Colors.grey.shade800],
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
          decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(wt * 0.04)),
        ),
      ),
    );
  }

  Widget _buildLoadingMoreIndicator() {
    return Container(
      padding: EdgeInsets.all(wt * 0.05),
      child: Center(child: LoadingAnimationWidget.progressiveDots(color: Colors.green, size: wt * 0.1)),
    );
  }

  void _navigateToPreview(int movieId) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MoviePreview(movieId: movieId)),
    );
  }
}

// ==================== SUB WIDGETS ====================

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

  @override
  Widget build(BuildContext context) {
    final posterPath = movie['poster_path'];
    final title = movie['title'] ?? 'Unknown';
    final releaseDate = movie['release_date'] ?? 'N/A';
    final voteAverage = (movie['vote_average'] ?? 0).toDouble();
    final rating = voteAverage / 2;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(wt * 0.045),
          border: Border.all(
            color: Colors.grey.shade800.withOpacity(0.3),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
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
                  _buildPosterImage(posterPath),
                  _buildGradientOverlay(),
                  _buildFavoriteButton(),
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
                    Text(
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
                    SizedBox(height: wt * 0.01),
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: wt * 0.028,
                          color: Colors.white54,
                        ),
                        SizedBox(width: wt * 0.01),
                        Text(
                          releaseDate.split('-').first,
                          style: TextStyle(
                            color: Colors.white54,
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
          color: const Color(0xFF252525),
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
      color: const Color(0xFF252525),
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
            colors: [
              Colors.black.withOpacity(0.7),
              Colors.transparent,
            ],
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
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(wt * 0.025),
            border: Border.all(
              color: Colors.white.withOpacity(0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
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
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(wt * 0.02),
          border: Border.all(
            color: _getRatingColor(rating).withOpacity(0.5),
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