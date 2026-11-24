import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:lottie/lottie.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/provider/client.dart';
import 'package:provider/provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:shimmer/shimmer.dart';

import '../../main.dart';

class Favorite extends ConsumerStatefulWidget {
  const Favorite({super.key});

  @override
  ConsumerState<Favorite> createState() => _FavoriteState();
}

class _FavoriteState extends ConsumerState<Favorite>
    with TickerProviderStateMixin {
  List favorites = [];
  String clientId = '';
  List isDeleting = [];
  List searched = [];
  bool isClearing = false;
  bool notFound = false;
  bool load = false;
  TextEditingController favoritesSearch = TextEditingController();

  // Animation controllers
  late AnimationController _fadeController;
  late AnimationController _headerController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _headerSlideAnimation;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    getLiked();
  }

  void _initAnimations() {
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _headerController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOut));
    _headerSlideAnimation =
        Tween<Offset>(begin: const Offset(0, -0.5), end: Offset.zero).animate(
          CurvedAnimation(parent: _headerController, curve: Curves.easeOutBack),
        );

    _headerController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _headerController.dispose();
    favoritesSearch.dispose();
    super.dispose();
  }

  Future<void> getLiked({bool isCleared = false}) async {
    if (!isCleared) setState(() => load = true);
    clientId = Provider.of<ClientProvider>(context, listen: false).clientId!;
    var client = FirebaseFirestore.instance
        .collection(AppConstants.phone)
        .doc(clientId);
    var liks = await client
        .collection('liked')
        .where('delete', isEqualTo: false)
        .orderBy('timeStamp', descending: true)
        .get();
    if (mounted) {
      setState(() {
        favorites = liks.docs.map((doc) {
          final data = doc.data();
          data['id'] = doc.id; // ✅ ensure id exists
          return data;
        }).toList();
        load = false;
      });
      _fadeController.forward();
    }
  }

  Future<void> removeFav({
    required Map<String, dynamic> item,
    required int index,
  }) async {
    final String id = item['id'].toString();
    final String title = item['title'];

    setState(() {
      isDeleting.add(id);
    });

    HapticFeedback.mediumImpact();

    int attempt = 0;
    while (attempt < 3) {
      try {
        await FirebaseFirestore.instance
            .collection(AppConstants.phone)
            .doc(clientId)
            .collection('liked')
            .doc(id)
            .update({'delete': true});

        if (mounted) {
          setState(() {
            isDeleting.remove(id);
          });
          await _showRemovalSnackBar(title, id, item, index);
        }
        return;
      } catch (e) {
        attempt++;

        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 2));
        } else {
          if (mounted) {
            showScaffoldMsg(
              context,
              txt: 'Failed to remove. Please try again.',
            );
            setState(() {
              isDeleting.remove(id);
            });
          }
        }
      }
    }
  }

  Future<void> _showRemovalSnackBar(
    String title,
    String id,
    dynamic removedItem,
    int removedIndex,
  ) async {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1E1E1E),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.all(wt * 0.04),
        padding: EdgeInsets.symmetric(
          horizontal: wt * 0.04,
          vertical: ht * 0.015,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(wt * 0.04),
        ),
        content: Row(
          children: [
            Container(
              padding: EdgeInsets.all(wt * 0.02),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check, color: Colors.green, size: wt * 0.045),
            ),
            SizedBox(width: wt * 0.03),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Removed from favorites',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: wt * 0.035,
                    ),
                  ),
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: wt * 0.03,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: Colors.amber,
          onPressed: () async {
            await _undoRemoval(removedItem, removedIndex);
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
    await Future.delayed(Duration(seconds: 3));
    ScaffoldMessenger.of(context).clearSnackBars();
  }

  Future<void> _undoRemoval(dynamic item, int index) async {
    try {
      final Map<String, dynamic> data = item is QueryDocumentSnapshot
          ? Map<String, dynamic>.from(item.data() as Map<String, dynamic>)
          : Map<String, dynamic>.from(item);

      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(clientId)
          .collection('liked')
          .doc(item['id'].toString())
          .set(data);

      setState(() {
        favorites.insert(index.clamp(0, favorites.length), item);

        // 🔥 FIX: restore into searched list if search active
        if (favoritesSearch.text.isNotEmpty &&
            item['title'].toLowerCase().contains(
              favoritesSearch.text.toLowerCase(),
            )) {
          searched.insert(0, item);
        }
      });

      HapticFeedback.lightImpact();
    } catch (e) {
      showScaffoldMsg(context, txt: 'Failed to restore item');
    }
  }

  Future<void> _showClearAllDialog() async {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(wt * 0.05),
        ),
        title: Row(
          children: [
            Container(
              padding: EdgeInsets.all(wt * 0.025),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Amicons.iconly_delete,
                color: Colors.red,
                size: wt * 0.06,
              ),
            ),
            SizedBox(width: wt * 0.03),
            Text(
              'Clear All?',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: wt * 0.05,
              ),
            ),
          ],
        ),
        content: Text(
          'This will remove all ${favorites.length} movies from your favorites. This action cannot be undone.',
          style: TextStyle(color: Colors.grey[400], fontSize: wt * 0.038),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Colors.grey[400],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.red[600]!, Colors.red[800]!],
              ),
              borderRadius: BorderRadius.circular(wt * 0.02),
            ),
            child: TextButton(
              onPressed: () {
                Navigator.pop(context);
                _clearAllFavorites();
              },
              child: const Text(
                'Clear All',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAllFavorites() async {
    HapticFeedback.heavyImpact();
    setState(() {
      isClearing = true;
    });

    for (var fav in favorites) {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(clientId)
          .collection('liked')
          .doc(fav['id'].toString())
          .update({'delete': true});
    }

    await getLiked(isCleared: true);
    setState(() {
      isClearing = false;
      searched.clear();
      favoritesSearch.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        ref.read(currentIndexProvider.notifier).state = 0;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: SafeArea(
          child: Column(
            children: [_buildHeader(), _buildSearchBar(), _buildContent(ref)],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SlideTransition(
      position: _headerSlideAnimation,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          wt * 0.05,
          ht * 0.02,
          wt * 0.05,
          ht * 0.015,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Amicons.iconly_heart,
                        color: Colors.green,
                        size: wt * 0.07,
                      ),
                      SizedBox(width: wt * 0.02),
                      Text(
                        'My Favorites',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: wt * 0.07,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: ht * 0.005),
                  Text(
                    'Your curated movie collection',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: wt * 0.035,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            _buildCountBadge(),
          ],
        ),
      ),
    );
  }

  Widget _buildCountBadge() {
    return Hero(
      tag: 'favorites_count',
      child: Container(
        width: wt * 0.16,
        height: wt * 0.16,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.green, Colors.green.withValues(alpha: 0.2)],
          ),
          borderRadius: BorderRadius.circular(wt * 0.045),
        ),
        child: Center(
          child: load
              ? LoadingAnimationWidget.staggeredDotsWave(
                  color: Colors.white,
                  size: wt * 0.05,
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      favorites.length.toString(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: wt * 0.055,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'movies',
                      style: TextStyle(
                        fontSize: wt * 0.025,
                        color: Colors.white70,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: wt * 0.05, vertical: ht * 0.01),
      child: Row(
        children: [
          Expanded(
            flex: 7,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(wt * 0.04),
                border: Border.all(
                  color: favoritesSearch.text.isNotEmpty
                      ? Colors.amber.withOpacity(0.5)
                      : Colors.grey[800]!,
                  width: 1.5,
                ),
              ),
              child: TextFormField(
                enabled: favorites.isNotEmpty,
                textInputAction: TextInputAction.search,
                onChanged: _handleSearch,
                textCapitalization: TextCapitalization.words,
                controller: favoritesSearch,
                cursorColor: Colors.grey,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: wt * 0.04,
                ),
                decoration: InputDecoration(
                  fillColor: Colors.transparent,
                  filled: true,
                  hintText: 'Search your favorites...',
                  hintStyle: TextStyle(
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w400,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: favoritesSearch.text.isNotEmpty
                        ? Colors.green
                        : Colors.grey[600],
                  ),
                  suffixIcon: favoritesSearch.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.clear,
                            color: Colors.grey[500],
                            size: wt * 0.05,
                          ),
                          onPressed: () {
                            favoritesSearch.clear();
                            setState(() {
                              searched.clear();
                              notFound = false;
                            });
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: wt * 0.04,
                    vertical: ht * 0.018,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: wt * 0.03),
          _buildClearButton(),
        ],
      ),
    );
  }

  void _handleSearch(String value) {
    final query = value.toLowerCase().trim();

    if (query.isEmpty) {
      setState(() {
        searched.clear();
        notFound = false;
      });
      return;
    }

    final results = favorites.where((fav) {
      return fav['title'].toLowerCase().contains(query);
    }).toList();

    setState(() {
      searched = results;
      notFound = results.isEmpty;
    });
  }

  Widget _buildClearButton() {
    final bool isEnabled = favorites.isNotEmpty && !isClearing;
    return Expanded(
      flex: 3,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          gradient: isEnabled
              ? LinearGradient(colors: [Colors.red[600]!, Colors.red[800]!])
              : LinearGradient(colors: [Colors.grey[700]!, Colors.grey[800]!]),
          borderRadius: BorderRadius.circular(wt * 0.04),
          boxShadow: isEnabled
              ? [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isEnabled ? _showClearAllDialog : null,
            borderRadius: BorderRadius.circular(wt * 0.04),
            child: SizedBox(
              height: ht * 0.06,
              child: Center(
                child: isClearing
                    ? LoadingAnimationWidget.horizontalRotatingDots(
                        color: Colors.white,
                        size: wt * 0.07,
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Amicons.iconly_delete,
                            color: isEnabled ? Colors.white : Colors.grey[500],
                            size: wt * 0.045,
                          ),
                          SizedBox(width: wt * 0.015),
                          Text(
                            'Clear',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isEnabled
                                  ? Colors.white
                                  : Colors.grey[500],
                              fontSize: wt * 0.033,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(WidgetRef ref) {
    if (load) {
      return _buildLoadingShimmer();
    }

    if (favorites.isEmpty) {
      return Expanded(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(wt * 0.05),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(wt * 0.08),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: LottieBuilder.asset(
                      'assets/lottie/not_found.json',
                      width: wt * 0.4,
                      height: wt * 0.4,
                    ),
                  ),
                  SizedBox(height: ht * 0.03),
                  Text(
                    'No favorites yet',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: wt * 0.06,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: ht * 0.01),
                  Text(
                    'Start adding movies to your collection\nby tapping the heart icon',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: wt * 0.038,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: ht * 0.04),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(wt * 0.04),
                      color: Colors.blueGrey,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          ref.read(currentIndexProvider.notifier).state = 0;

                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (context) => MainScreen(),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(wt * 0.04),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: wt * 0.1,
                            vertical: ht * 0.02,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.movie_outlined,
                                color: Colors.white,
                                size: wt * 0.05,
                              ),
                              SizedBox(width: wt * 0.02),
                              Text(
                                'Browse Movies',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: wt * 0.045,
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
            ),
          ),
        ),
      );
    }

    if (notFound) {
      return _buildNotFoundState();
    }

    return _buildFavoritesList();
  }

  Widget _buildLoadingShimmer() {
    return Expanded(
      child: Shimmer(
        direction: ShimmerDirection.ltr,
        period: const Duration(milliseconds: 1200),
        gradient: LinearGradient(
          colors: [
            Colors.grey.shade900,
            Colors.grey.shade700,
            Colors.grey.shade900,
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
        child: Padding(
          padding: EdgeInsets.all(wt * 0.05),
          child: ListView.separated(
            physics: const NeverScrollableScrollPhysics(),
            separatorBuilder: (context, index) => SizedBox(height: ht * 0.02),
            itemCount: 4,
            itemBuilder: (context, index) {
              return Container(
                width: wt,
                height: ht * 0.18,
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(wt * 0.05),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildNotFoundState() {
    return Expanded(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(wt * 0.05),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_off_rounded,
                color: Colors.grey[600],
                size: wt * 0.2,
              ),
              SizedBox(height: ht * 0.02),
              Text(
                'No results found',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: wt * 0.05,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: ht * 0.01),
              Text(
                'Try searching with different keywords',
                style: TextStyle(color: Colors.grey[500], fontSize: wt * 0.035),
              ),
              SizedBox(height: ht * 0.02),
              TextButton(
                onPressed: () {
                  favoritesSearch.clear();
                  setState(() {
                    searched.clear();
                    notFound = false;
                  });
                },
                child: Text(
                  'Clear search',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFavoritesList() {
    final currentData = searched.isNotEmpty ? searched : favorites;

    return Expanded(
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: RefreshIndicator(
          onRefresh: getLiked,
          color: Colors.green,
          backgroundColor: const Color(0xFF1A1A1A),
          child: ListView.builder(
            padding: EdgeInsets.all(wt * 0.05),
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            itemCount: currentData.length,
            itemBuilder: (context, index) {
              return TweenAnimationBuilder<double>(
                duration: Duration(milliseconds: 300 + (index * 50)),
                tween: Tween(begin: 0.0, end: 1.0),
                builder: (context, value, child) {
                  return Transform.translate(
                    offset: Offset(0, 30 * (1 - value)),
                    child: Opacity(opacity: value, child: child),
                  );
                },
                child: Padding(
                  padding: EdgeInsets.only(bottom: ht * 0.02),
                  child: _buildFavoriteCard(currentData[index], index),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFavoriteCard(dynamic item, int index) {
    final bool isItemDeleting = isDeleting.contains(item['id'].toString());

    return Dismissible(
      key: Key(item['id'].toString()),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        HapticFeedback.mediumImpact();
        return await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text(
              'Remove favorite?',
              style: TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Remove',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        );
      },
      onDismissed: (direction) {
        final removedItem = Map<String, dynamic>.from(item);

        setState(() {
          favorites.removeWhere((e) => e['id'] == removedItem['id']);
          searched.removeWhere((e) => e['id'] == removedItem['id']);
        });

        removeFav(item: removedItem, index: index);
      },

      background: Container(
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: wt * 0.05),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.red[400]!, Colors.red[700]!],
          ),
          borderRadius: BorderRadius.circular(wt * 0.05),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Amicons.iconly_delete, color: Colors.white, size: wt * 0.08),
            SizedBox(height: ht * 0.005),
            Text(
              'Remove',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: wt * 0.035,
              ),
            ),
          ],
        ),
      ),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MoviePreview(movieId: item['id']),
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(wt * 0.05),
            border: Border.all(color: Colors.grey[850]!, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(wt * 0.05),
            child: Row(
              children: [
                _buildMoviePoster(item, isItemDeleting),
                Expanded(child: _buildMovieInfo(item, isItemDeleting)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMoviePoster(dynamic item, bool isItemDeleting) {
    return Stack(
      children: [
        Hero(
          tag: 'movie_${item['id']}',
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(wt * 0.05),
              bottomLeft: Radius.circular(wt * 0.05),
            ),
            child: SizedBox(
              width: wt * 0.28,
              height: ht * 0.2,
              child: CachedNetworkImage(
                errorWidget: (context, url, error) => Container(
                  color: Colors.grey[900],
                  child: Icon(
                    Amicons.iconly_image_2_fill,
                    size: wt * 0.15,
                    color: Colors.white30,
                  ),
                ),
                imageUrl: item['img'] ?? '',
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  color: Colors.grey[900],
                  child: Center(
                    child: LoadingAnimationWidget.fourRotatingDots(
                      color: Colors.green,
                      size: wt * 0.06,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Delete button overlay
        Positioned(
          top: 0,
          left: 0,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: isItemDeleting
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      removeFav(item: item, index: favorites.indexOf(item));
                    },
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(wt * 0.05),
                bottomRight: Radius.circular(wt * 0.04),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: EdgeInsets.all(wt * 0.025),
                decoration: BoxDecoration(
                  color: isItemDeleting
                      ? Colors.black.withOpacity(0.8)
                      : Colors.red.shade800.withOpacity(0.9),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(wt * 0.05),
                    bottomRight: Radius.circular(wt * 0.04),
                  ),
                ),
                child: isItemDeleting
                    ? LoadingAnimationWidget.threeArchedCircle(
                        color: Colors.white,
                        size: wt * 0.05,
                      )
                    : Icon(
                        Amicons.iconly_delete,
                        color: Colors.white,
                        size: wt * 0.05,
                      ),
              ),
            ),
          ),
        ),
        // Play icon overlay
        Positioned.fill(
          child: Center(
            child: Container(
              padding: EdgeInsets.all(wt * 0.025),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: wt * 0.06,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMovieInfo(dynamic item, bool isItemDeleting) {
    return Container(
      height: ht * 0.2,
      padding: EdgeInsets.all(wt * 0.04),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Title
          Text(
            item['title'],
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: wt * 0.042,
              height: 1.2,
            ),
          ),
          // Rating and Year
          Row(
            children: [
              _buildRatingBadge(item['rating']),
              SizedBox(width: wt * 0.02),
              _buildYearBadge(item['year']),
            ],
          ),
          // View Details Button
          _buildDetailsButton(item),
        ],
      ),
    );
  }

  Widget _buildRatingBadge(dynamic rating) {
    final double ratingValue = (rating / 2);
    final Color ratingColor = ratingValue >= 4
        ? Colors.green
        : ratingValue >= 3
        ? Colors.amber
        : Colors.red;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: wt * 0.025,
        vertical: wt * 0.015,
      ),
      decoration: BoxDecoration(
        color: ratingColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(wt * 0.02),
        border: Border.all(color: ratingColor.withOpacity(0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, color: ratingColor, size: wt * 0.04),
          SizedBox(width: wt * 0.01),
          Text(
            ratingValue.toStringAsFixed(1),
            style: TextStyle(
              color: ratingColor,
              fontWeight: FontWeight.bold,
              fontSize: wt * 0.032,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildYearBadge(String year) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: wt * 0.025,
        vertical: wt * 0.015,
      ),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.2),
        borderRadius: BorderRadius.circular(wt * 0.02),
        border: Border.all(color: Colors.grey.withOpacity(0.3), width: 1),
      ),
      child: Text(
        year,
        style: TextStyle(
          color: Colors.grey[400],
          fontWeight: FontWeight.w600,
          fontSize: wt * 0.032,
        ),
      ),
    );
  }

  Widget _buildDetailsButton(dynamic item) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.green.shade900,
          borderRadius: BorderRadius.circular(wt * 0.025),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MoviePreview(movieId: item['id']),
                ),
              );
            },
            borderRadius: BorderRadius.circular(wt * 0.025),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: ht * 0.012),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: Colors.white,
                    size: wt * 0.04,
                  ),
                  SizedBox(width: wt * 0.015),
                  Text(
                    'View Details',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: wt * 0.035,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
