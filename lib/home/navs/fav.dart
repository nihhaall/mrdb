import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/provider/favorites_provider.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';
import 'package:provider/provider.dart' as p;
import 'package:shimmer/shimmer.dart';

import '../../main.dart';

class Favorite extends ConsumerStatefulWidget {
  const Favorite({super.key});

  @override
  ConsumerState<Favorite> createState() => _FavoriteState();
}

class _FavoriteState extends ConsumerState<Favorite> {
  final TextEditingController _searchController = TextEditingController();
  bool _isClearing = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _removeFavorite(
    Map<String, dynamic> item,
    int index,
    FavoritesProvider favProvider,
  ) async {
    HapticFeedback.mediumImpact();
    final movieId = item['movId'] ?? item['id'];

    if (movieId == null) return;

    // Use provider to remove favorite (optimistic & synced)
    await favProvider.removeFavorite(movieId);
  }

  Future<void> _showClearAllBottomSheet(FavoritesProvider favProvider) async {
    HapticFeedback.lightImpact();
    final count = favProvider.count;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: const BoxDecoration(
          color: Color(0xFF141622),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0xFF282D3D), width: 1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 22),
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: const Color(0xFFFF4D4D).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_sweep_rounded,
                color: Color(0xFFFF5252),
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Clear All Favorites?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This will remove all $count movies from your favorites watchlist.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF2A2F42)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Clear All',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
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

    if (confirmed == true) {
      HapticFeedback.heavyImpact();
      setState(() => _isClearing = true);
      try {
        await favProvider.clearAll();
        if (mounted) {
          _searchController.clear();
        }
      } catch (e) {
        debugPrint('Clear all error: $e');
        if (mounted) {
          showScaffoldMsg(context, txt: 'Failed to clear favorites');
        }
      } finally {
        if (mounted) {
          setState(() => _isClearing = false);
        }
      }
    }
  }

  String _formatPosterUrl(dynamic rawImg) {
    if (rawImg == null) return '';
    final str = rawImg.toString().trim();
    if (str.isEmpty) return '';
    if (str.startsWith('http://') || str.startsWith('https://')) {
      return str;
    }
    if (str.startsWith('/')) {
      return '${AppConstants.baseImageUrl}$str';
    }
    return '${AppConstants.baseImageUrl}/$str';
  }

  String _formatYear(dynamic rawYear) {
    if (rawYear == null) return '';
    final str = rawYear.toString().trim();
    if (str.isEmpty) return '';
    try {
      final date = DateTime.tryParse(str);
      if (date != null) {
        if (date.isAfter(DateTime.now())) {
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
          return '${months[date.month - 1]} ${date.day}, ${date.year}';
        }
        return date.year.toString();
      }
    } catch (_) {}
    if (str.contains('-')) {
      return str.split('-').first;
    }
    if (str.length >= 4) {
      return str.substring(0, 4);
    }
    return str;
  }

  double _parseRating(dynamic rawRating) {
    if (rawRating == null) return 0.0;
    if (rawRating is num) {
      return rawRating.toDouble();
    }
    return double.tryParse(rawRating.toString()) ?? 0.0;
  }

  // ── Hero Flight Shuttles (identical to home_page.dart) ─────────────────────

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
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.fastOutSlowIn,
    );
    final String text =
        (toHeroContext.widget is Hero &&
            (toHeroContext.widget as Hero).child is Material &&
            ((toHeroContext.widget as Hero).child as Material).child is Text)
        ? (((toHeroContext.widget as Hero).child as Material).child as Text)
                  .data ??
              ''
        : ((fromHeroContext.widget is Hero &&
                  (fromHeroContext.widget as Hero).child is Material &&
                  ((fromHeroContext.widget as Hero).child as Material).child
                      is Text)
              ? (((fromHeroContext.widget as Hero).child as Material).child
                            as Text)
                        .data ??
                    ''
              : '');

    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) {
        return DefaultTextStyle(
          style: TextStyle.lerp(
            const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
            const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
            curved.value,
          )!,
          child: Material(
            type: MaterialType.transparency,
            child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        );
      },
    );
  }

  void _navigateToPreview(Map<String, dynamic> item) {
    HapticFeedback.lightImpact();
    final movieId = item['movId'] ?? item['id'];
    final title = (item['title'] ?? item['name'] ?? 'Movie').toString();
    final posterUrl = _formatPosterUrl(item['img'] ?? item['poster_path']);
    final rating = _parseRating(item['rating']);
    final year = _formatYear(item['year'] ?? item['release_date']);

    String? posterPath;
    if (item['poster_path'] != null &&
        item['poster_path'].toString().isNotEmpty) {
      posterPath = item['poster_path'].toString();
    } else if (item['img'] != null && item['img'].toString().isNotEmpty) {
      final imgStr = item['img'].toString();
      if (imgStr.contains('/t/p/')) {
        posterPath =
            '/${imgStr.split('/t/p/').last.replaceFirst(RegExp(r'^[^\/]+\/'), '')}';
      } else if (imgStr.startsWith('/')) {
        posterPath = imgStr;
      } else {
        posterPath = posterUrl;
      }
    }

    final enrichedMovie = {
      'id': movieId,
      'title': title,
      'name': title,
      'poster_path': posterPath,
      'backdrop_path': item['backdrop_path'],
      'vote_average': rating,
      'release_date': item['year'] ?? item['release_date'],
    };

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (context, animation, secondaryAnimation) {
          return MoviePreview(
            movieId: movieId,
            initialMovie: enrichedMovie,
            posterPath: posterPath,
            title: title,
            backdropPath: item['backdrop_path'],
            subtitle: year,
            heroTag: 'fav_movie_hero_$movieId',
            titleHeroTag: 'fav_movie_title_$movieId',
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

  @override
  Widget build(BuildContext context) {
    final favProvider = p.Provider.of<FavoritesProvider>(context);
    final allFavorites = favProvider.favorites;
    final screenWidth = MediaQuery.of(context).size.width;

    // Filter by search query
    final query = _searchController.text.trim().toLowerCase();
    final filteredFavorites = query.isEmpty
        ? allFavorites
        : allFavorites.where((fav) {
            final title = (fav['title'] ?? '').toString().toLowerCase();
            return title.contains(query);
          }).toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        ref.read(currentIndexProvider.notifier).state = 0;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D14),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(favProvider),
              _buildSearchBar(allFavorites.isNotEmpty),
              Expanded(
                child: _buildBody(favProvider, filteredFavorites, screenWidth),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(FavoritesProvider favProvider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Title & count
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Amicons.iconly_heart_fill,
                    color: Color(0xFF00E5A0),
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Favorites',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                favProvider.isLoading
                    ? 'Loading your collection...'
                    : '${favProvider.count} ${favProvider.count == 1 ? 'movie' : 'movies'} saved',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),

          // Clear all button (only shown when favorites exist)
          if (favProvider.favorites.isNotEmpty)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _isClearing ? 0.5 : 1.0,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isClearing
                      ? null
                      : () => _showClearAllBottomSheet(favProvider),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161824),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF282D3D),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isClearing)
                          LoadingAnimationWidget.threeArchedCircle(
                            color: Colors.white70,
                            size: 14,
                          )
                        else
                          const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.white70,
                            size: 16,
                          ),
                        const SizedBox(width: 5),
                        const Text(
                          'Clear',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool hasFavorites) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF141722),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _searchController.text.isNotEmpty
                ? const Color(0xFF00E5A0).withValues(alpha: 0.5)
                : const Color(0xFF222738),
            width: 1,
          ),
        ),
        child: TextField(
          controller: _searchController,
          enabled: hasFavorites || _searchController.text.isNotEmpty,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
          ),
          cursorColor: const Color(0xFF00E5A0),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: 'Search in favorites...',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: Color(0xFF00E5A0),
              size: 20,
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      _searchController.clear();
                      setState(() {});
                    },
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white54,
                      size: 18,
                    ),
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    FavoritesProvider favProvider,
    List<Map<String, dynamic>> filteredFavorites,
    double screenWidth,
  ) {
    if (favProvider.isLoading) {
      return _buildShimmerLoading(screenWidth);
    }

    if (favProvider.hasError && favProvider.isEmpty) {
      return NetworkStateView(
        failureType: favProvider.failureType,
        customMessage: favProvider.errorMessage,
        onRetry: favProvider.refresh,
      );
    }

    if (favProvider.isEmpty) {
      return _buildEmptyState();
    }

    if (filteredFavorites.isEmpty && _searchController.text.isNotEmpty) {
      return _buildNotFoundState();
    }

    return RefreshIndicator(
      onRefresh: favProvider.refresh,
      color: const Color(0xFF00E5A0),
      backgroundColor: const Color(0xFF141722),
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(
          screenWidth * 0.04,
          12,
          screenWidth * 0.04,
          110,
        ),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: filteredFavorites.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: screenWidth * 0.035,
          mainAxisSpacing: screenWidth * 0.04,
          mainAxisExtent: screenWidth * 0.78,
        ),
        itemBuilder: (context, index) {
          final item = filteredFavorites[index];
          return _buildFavoriteCard(item, index, favProvider);
        },
      ),
    );
  }

  Widget _buildFavoriteCard(
    Map<String, dynamic> item,
    int index,
    FavoritesProvider favProvider,
  ) {
    final movieId = item['movId'] ?? item['id'];
    final title = (item['title'] ?? item['name'] ?? 'Unknown').toString();
    final posterUrl = _formatPosterUrl(item['img'] ?? item['poster_path']);
    final rating = _parseRating(item['rating']);
    final year = _formatYear(item['year'] ?? item['release_date']);
    final isDeleting = favProvider.isMovieLoading(movieId);

    return GestureDetector(
      onTap: () => _navigateToPreview(item),
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
                  // Poster Hero (distinct tag to avoid IndexedStack collision with HomePage)
                  Hero(
                    tag: 'fav_movie_hero_$movieId',
                    createRectTween: (begin, end) =>
                        MaterialRectCenterArcTween(begin: begin, end: end),
                    flightShuttleBuilder: _buildPosterFlightShuttle,
                    child: Material(
                      type: MaterialType.transparency,
                      child: posterUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: posterUrl,
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
                                  _buildErrorPoster(),
                            )
                          : _buildErrorPoster(),
                    ),
                  ),

                  // Rating Badge (Top-Left)
                  if (rating > 0)
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
                              rating.toStringAsFixed(1),
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
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _removeFavorite(item, index, favProvider);
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: isDeleting
                              ? LoadingAnimationWidget.fallingDot(
                                  color: Colors.red,
                                  size: 14,
                                )
                              : const Icon(
                                  Amicons.iconly_heart_fill,
                                  color: Colors.red,
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
            tag: 'fav_movie_title_$movieId',
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
          if (year.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              year,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorPoster() {
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

  Widget _buildShimmerLoading(double screenWidth) {
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
        padding: EdgeInsets.fromLTRB(
          screenWidth * 0.04,
          12,
          screenWidth * 0.04,
          110,
        ),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 4,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: screenWidth * 0.035,
          mainAxisSpacing: screenWidth * 0.04,
          mainAxisExtent: screenWidth * 0.78,
        ),
        itemBuilder: (context, index) => Container(
          decoration: BoxDecoration(
            color: Colors.white38,
            borderRadius: BorderRadius.circular(screenWidth * 0.04),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: const Color(0xFF141724),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF00E5A0).withValues(alpha: 0.25),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5A0).withValues(alpha: 0.08),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Amicons.iconly_heart,
                  color: Color(0xFF00E5A0),
                  size: 38,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Your Watchlist is Empty',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Explore movies and tap the heart icon to save titles you want to watch later.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                HapticFeedback.lightImpact();
                ref.read(currentIndexProvider.notifier).state = 0;
              },
              icon: const Icon(Icons.explore_rounded, size: 18),
              label: const Text(
                'Browse Movies',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5A0),
                foregroundColor: const Color(0xFF0A0D14),
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotFoundState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: const BoxDecoration(
                color: Color(0xFF141724),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(
                  Icons.search_off_rounded,
                  color: Colors.white38,
                  size: 32,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No matching movies',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'We couldn\'t find any saved movie matching "${_searchController.text.trim()}"',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: () {
                _searchController.clear();
                setState(() {});
              },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF00E5A0),
              ),
              child: const Text(
                'Clear search',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
