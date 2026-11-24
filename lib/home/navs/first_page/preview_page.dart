import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rating/flutter_rating.dart';
import 'package:http/http.dart' as http;
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:provider/provider.dart';
import 'package:readmore/readmore.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../../../constens/keys.dart';
import '../../../main.dart';
import '../../../models/movie_model.dart';
import '../../../provider/client.dart';

class MoviePreview extends StatefulWidget {
  final dynamic movieId;
  final Map<String, dynamic>? initialMovie;
  final String? posterPath;
  final String? title;
  final String? backdropPath;

  const MoviePreview({
    super.key,
    required this.movieId,
    this.initialMovie,
    this.posterPath,
    this.title,
    this.backdropPath,
  });

  @override
  State<MoviePreview> createState() => _MoviePreviewState();
}

class _MoviePreviewState extends State<MoviePreview> {
  final Random random = Random();
  bool islod = false;
  bool videoLoading = false;
  bool isFavorite = false;
  bool isFavLoading = false;
  double? userRating;

  Map<String, dynamic> movi = {};
  var genre = [];
  var actors = [];
  Map videos = {};
  List videoList = [];
  List reviews = [];

  @override
  void initState() {
    super.initState();
    if (widget.initialMovie != null) {
      movi = Map<String, dynamic>.from(widget.initialMovie!);
      if (movi['title'] == null && movi['name'] != null) {
        movi['title'] = movi['name'];
      }
      islod = false;
    } else if (widget.title != null || widget.posterPath != null) {
      movi = {
        'title': widget.title,
        'poster_path': widget.posterPath,
        'backdrop_path': widget.backdropPath,
      };
      islod = false;
    } else {
      islod = true;
    }
    getMovieDetails();
    _checkFavoriteStatus();
    _checkRatingStatus();
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

  Future<void> _checkRatingStatus() async {
    try {
      final clientProvider = Provider.of<ClientProvider>(
        context,
        listen: false,
      );
      final clientId = clientProvider.clientId;
      if (clientId == null) return;
      final doc = await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(clientId)
          .collection('ratings')
          .doc(widget.movieId.toString())
          .get();
      if (mounted && doc.exists && doc.data()?['rating'] != null) {
        setState(() {
          userRating = (doc.data()!['rating'] as num).toDouble();
        });
      }
    } catch (_) {}
  }

  Future<void> _checkFavoriteStatus() async {
    try {
      final clientProvider = Provider.of<ClientProvider>(
        context,
        listen: false,
      );
      final clientId = clientProvider.clientId;
      if (clientId == null) return;
      final doc = await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(clientId)
          .collection('liked')
          .doc(widget.movieId.toString())
          .get();
      if (mounted) {
        setState(() {
          isFavorite = doc.exists && (doc.data()?['delete'] != true);
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    if (movi.isEmpty) return;
    try {
      final clientProvider = Provider.of<ClientProvider>(
        context,
        listen: false,
      );
      final clientId = clientProvider.clientId;
      if (clientId == null) return;
      setState(() => isFavLoading = true);
      HapticFeedback.lightImpact();

      final docRef = FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(clientId)
          .collection('liked')
          .doc(widget.movieId.toString());

      if (isFavorite) {
        await docRef.update({'delete': true});
        if (mounted) {
          setState(() {
            isFavorite = false;
            isFavLoading = false;
          });
          showScaffoldMsg(context, txt: 'Removed from My List');
        }
      } else {
        final movie = Movie(
          movId: int.tryParse(widget.movieId.toString()) ?? 0,
          title: movi['title'] ?? '',
          img: movi['poster_path'] != null
              ? '${AppConstants.baseImageUrl}${movi['poster_path']}'
              : '',
          year: movi['release_date'] ?? '',
          rating: (movi['vote_average'] is num)
              ? (movi['vote_average'] as num).toDouble()
              : 0.0,
          timeStamp: DateTime.now(),
          delete: false,
        );
        await docRef.set(movie.toMap());
        if (mounted) {
          setState(() {
            isFavorite = true;
            isFavLoading = false;
          });
          showScaffoldMsg(context, txt: 'Added to My List ❤️');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => isFavLoading = false);
        showScaffoldMsg(context, txt: 'Error updating favorite');
      }
    }
  }

  void _shareMovie() {
    final title = movi['title'] ?? 'Movie';
    final url = 'https://www.themoviedb.org/movie/${widget.movieId}';
    Clipboard.setData(ClipboardData(text: 'Check out "$title" on MRDB: $url'));
    HapticFeedback.lightImpact();
    showScaffoldMsg(context, txt: 'Movie link copied to clipboard! 📋');
  }

  void _showRatingDialog() {
    if (userRating != null) {
      showScaffoldMsg(
        context,
        txt:
            'You already rated this movie: ${(userRating! * 2).toStringAsFixed(1)}/10 ⭐ (Rated once)',
      );
      return;
    }
    double selectedRating = ((movi['vote_average'] ?? 0) / 2)
        .clamp(1.0, 5.0)
        .toDouble();
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF181822),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              title: Text(
                'Rate "${movi['title'] ?? 'Movie'}"',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  StarRating(
                    size: 34,
                    rating: selectedRating,
                    color: Colors.amber,
                    borderColor: Colors.grey.shade700,
                    allowHalfRating: true,
                    onRatingChanged: (rating) {
                      setDialogState(() {
                        selectedRating = rating;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${(selectedRating * 2).toStringAsFixed(1)} / 10',
                    style: const TextStyle(
                      color: Color(0xFF00E5A0),
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              actionsAlignment: MainAxisAlignment.spaceEvenly,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5A0),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    Navigator.pop(dialogCtx);
                    setState(() {
                      userRating = selectedRating;
                    });
                    HapticFeedback.lightImpact();
                    showScaffoldMsg(
                      context,
                      txt:
                          'Rating saved: ${(selectedRating * 2).toStringAsFixed(1)}/10 ⭐',
                    );
                    try {
                      final clientProvider = Provider.of<ClientProvider>(
                        context,
                        listen: false,
                      );
                      final clientId = clientProvider.clientId;
                      if (clientId != null) {
                        await FirebaseFirestore.instance
                            .collection(AppConstants.phone)
                            .doc(clientId)
                            .collection('ratings')
                            .doc(widget.movieId.toString())
                            .set({
                              'movieId': widget.movieId.toString(),
                              'title': movi['title'] ?? 'Movie',
                              'rating': selectedRating,
                              'score': selectedRating * 2,
                              'timestamp': DateTime.now(),
                            });
                      }
                    } catch (_) {}
                  },
                  child: const Text(
                    'Submit',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> getMovieDetails() async {
    Uri url = Uri.parse(
      'https://api.themoviedb.org/3/movie/${widget.movieId}?api_key=${AppConstants.apiKey}&language=en',
    );
    Uri castUri = Uri.parse(
      'https://api.themoviedb.org/3/movie/${widget.movieId}/credits?api_key=${AppConstants.apiKey}&language=en',
    );

    if (movi.isEmpty) {
      setState(() {
        islod = true;
      });
    }

    try {
      final responses = await Future.wait([
        http.get(url).timeout(const Duration(seconds: 8)),
        http.get(castUri).timeout(const Duration(seconds: 8)),
      ]);

      if (responses[0].statusCode == 200) {
        final Map<String, dynamic> response = Map<String, dynamic>.from(
          jsonDecode(responses[0].body),
        );
        var genresList = response['genres'] as List? ?? [];
        final fetchedGenres = genresList
            .map((item) => item['name'].toString())
            .toList();

        if (mounted) {
          setState(() {
            movi = {...movi, ...response};
            if (fetchedGenres.isNotEmpty) {
              genre = fetchedGenres;
            }
            islod = false;
          });
        }
      }

      if (responses[1].statusCode == 200) {
        final castResponse = jsonDecode(responses[1].body);
        List allCast = castResponse['cast'] ?? [];
        final fetchedActors = allCast
            .where((element) => element['known_for_department'] == 'Acting')
            .toList();
        if (mounted) {
          setState(() {
            actors = fetchedActors;
          });
        }
      }

      // Fetch reviews asynchronously in background without blocking screen
      getReviews();
    } catch (e) {
      if (mounted) {
        setState(() {
          islod = false;
        });
      }
    }
  }

  Future<void> getReviews() async {
    Uri uri = Uri.parse(
      'https://api.themoviedb.org/3/movie/${widget.movieId}/reviews?api_key=${AppConstants.apiKey}',
    );

    int attempt = 0;
    while (attempt < 4) {
      try {
        http.Response response = await http.get(uri);
        var data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            reviews = data['results'] ?? [];
          });
        }
        return;
      } catch (e) {
        attempt++;
        if (attempt < 4) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
  }

  Future<void> getVideo() async {
    Uri uri = Uri.parse(
      'https://api.themoviedb.org/3/movie/${widget.movieId}/videos?api_key=${AppConstants.apiKey}',
    );
    int attempt = 0;

    while (attempt < 3) {
      try {
        http.Response response = await http.get(uri);
        if (response.statusCode == 200) {
          var jsonDe = jsonDecode(response.body)['results'] as List;
          var filtered = jsonDe
              .where(
                (element) =>
                    element['site'] == 'YouTube' &&
                    element['key'] != null &&
                    (element['key'] as String).isNotEmpty &&
                    (element['type'] == 'Trailer' ||
                        element['type'] == 'Teaser' ||
                        element['type'] == 'Clip'),
              )
              .toList();

          if (filtered.isNotEmpty) {
            filtered.sort((a, b) {
              int priority(dynamic item) {
                final type = (item['type'] ?? '').toString();
                final bool official =
                    item['official'] == true ||
                    (item['name'] ?? '').toString().toLowerCase().contains(
                      'official',
                    );
                if (type == 'Trailer' && official) return 0;
                if (type == 'Trailer') return 1;
                if (type == 'Teaser' && official) return 2;
                if (type == 'Teaser') return 3;
                return 4;
              }

              return priority(a).compareTo(priority(b));
            });

            if (mounted) {
              setState(() {
                videoList = filtered;
                videos = filtered.first;
              });
            }
            return;
          } else {
            if (mounted) {
              showScaffoldMsg(context, txt: 'No Trailer Available!!');
            }
            return;
          }
        } else {
          throw Exception(
            'HTTP ${response.statusCode}: ${response.reasonPhrase}',
          );
        }
      } catch (e) {
        attempt++;
        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 1));
        } else {
          if (mounted) {
            showScaffoldMsg(
              context,
              txt: 'Failed to load trailer. Please try again.',
            );
          }
          return;
        }
      }
    }
  }

  String _formatDate(dynamic dateString) {
    if (dateString == null) return 'Unknown date';
    try {
      final DateTime date = DateTime.parse(dateString.toString());
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
    } catch (_) {
      return dateString.toString();
    }
  }

  String _getYear(dynamic date) {
    if (date == null) return '';
    final str = date.toString();
    if (str.length >= 4) {
      return str.substring(0, 4);
    }
    return str;
  }

  String _formatRuntime(dynamic runtime) {
    if (runtime == null) return '';
    final minutes = (runtime is int)
        ? runtime
        : int.tryParse(runtime.toString()) ?? 0;
    if (minutes <= 0) return '';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h > 0) {
      return '${h}h ${m}m';
    }
    return '${m}m';
  }

  String _formatCurrency(dynamic amount) {
    if (amount == null) return 'N/A';
    final num val = (amount is num)
        ? amount
        : num.tryParse(amount.toString()) ?? 0;
    if (val <= 0) return 'N/A';
    if (val >= 1000000000) {
      return '\$${(val / 1000000000).toStringAsFixed(1)}B';
    }
    if (val >= 1000000) {
      return '\$${(val / 1000000).toStringAsFixed(1)}M';
    }
    if (val >= 1000) {
      return '\$${(val / 1000).toStringAsFixed(1)}K';
    }
    return '\$$val';
  }

  String imgUrl(dynamic path) {
    if (path == null || path.isEmpty) {
      return 'https://bioapdps.com.my/malayamedicalcentre/images/no-image/No-Image-Found-400x264.png';
    }
    if (path.startsWith('http')) return path;
    return '${AppConstants.baseImageUrl}$path';
  }

  @override
  Widget build(BuildContext context) {
    final backdropPath = movi['backdrop_path'] ?? movi['poster_path'];
    final backdrop = imgUrl(backdropPath);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D14),
      body: islod
          ? _buildModernShimmer()
          : CustomScrollView(
              slivers: [
                // 1. Cinematic Hero Header with Poster & Title in front of the Sliver
                SliverAppBar(
                  backgroundColor: const Color(0xFF0D0D14),
                  pinned: true,
                  elevation: 0,
                  expandedHeight: 330,
                  leadingWidth: 54,
                  leading: Padding(
                    padding: const EdgeInsets.only(left: 10.0),
                    child: Center(
                      child: _buildCircleNavButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                  actions: [
                    _buildCircleNavButton(
                      icon: isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: isFavorite
                          ? const Color(0xFFFF4D6D)
                          : Colors.white,
                      onPressed: _toggleFavorite,
                    ),
                    const SizedBox(width: 8),
                    _buildCircleNavButton(
                      icon: Icons.share_rounded,
                      onPressed: _shareMovie,
                    ),
                    const SizedBox(width: 12),
                  ],
                  flexibleSpace: LayoutBuilder(
                    builder: (context, constraints) {
                      final top = constraints.biggest.height;
                      final statusBarHeight = MediaQuery.of(
                        context,
                      ).padding.top;
                      final isCollapsed =
                          top <= (kToolbarHeight + statusBarHeight + 25);

                      return FlexibleSpaceBar(
                        centerTitle: false,
                        titlePadding: const EdgeInsets.only(
                          left: 54,
                          right: 104,
                          bottom: 15,
                        ),
                        title: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: isCollapsed ? 1.0 : 0.0,
                          child: Text(
                            movi['title'] ?? 'Movie',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16.5,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 1. Backdrop image
                            CachedNetworkImage(
                              imageUrl: backdrop,
                              fit: BoxFit.cover,
                              placeholder: (context, url) =>
                                  Container(color: const Color(0xFF14141E)),
                              errorWidget: (context, url, error) => Container(
                                color: const Color(0xFF14141E),
                                child: const Icon(
                                  Icons.movie_creation_outlined,
                                  size: 64,
                                  color: Colors.white24,
                                ),
                              ),
                            ),

                            // 2. Multi-stop gradient blend
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: const [0.0, 0.4, 0.72, 1.0],
                                  colors: [
                                    Colors.black.withValues(alpha: 0.65),
                                    Colors.transparent,
                                    const Color(
                                      0xFF0D0D14,
                                    ).withValues(alpha: 0.8),
                                    const Color(0xFF0D0D14),
                                  ],
                                ),
                              ),
                            ),

                            // 3. Movie Title & Poster right in front of the sliver
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 14,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: isCollapsed ? 0.0 : 1.0,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    // Movie Poster Card
                                    Hero(
                                      tag: 'movie_hero_${widget.movieId}',
                                      child: Material(
                                        type: MaterialType.transparency,
                                        child: Container(
                                          width: 96,
                                          height: 140,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.18,
                                              ),
                                              width: 1.2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.7,
                                                ),
                                                blurRadius: 18,
                                                offset: const Offset(0, 6),
                                              ),
                                            ],
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              13,
                                            ),
                                            child: CachedNetworkImage(
                                              imageUrl: imgUrl(
                                                movi['poster_path'] ??
                                                    widget.posterPath ??
                                                    movi['backdrop_path'] ??
                                                    widget.backdropPath,
                                              ),
                                              fit: BoxFit.cover,
                                              placeholder: (context, url) =>
                                                  Container(
                                                    color: const Color(
                                                      0xFF181824,
                                                    ),
                                                  ),
                                              errorWidget:
                                                  (
                                                    context,
                                                    url,
                                                    error,
                                                  ) => Container(
                                                    color: const Color(
                                                      0xFF181824,
                                                    ),
                                                    child: const Icon(
                                                      Icons
                                                          .broken_image_rounded,
                                                      color: Colors.white38,
                                                    ),
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),

                                    // Movie Title, Tagline & Metadata Badges
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Hero(
                                            tag:
                                                'movie_title_${widget.movieId}',
                                            flightShuttleBuilder:
                                                _buildTitleFlightShuttle,
                                            child: Material(
                                              type: MaterialType.transparency,
                                              child: Text(
                                                movi['title'] ??
                                                    movi['name'] ??
                                                    widget.title ??
                                                    'Movie',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: -0.3,
                                                  height: 1.2,
                                                  shadows: [
                                                    Shadow(
                                                      color: Colors.black87,
                                                      blurRadius: 6,
                                                      offset: Offset(0, 2),
                                                    ),
                                                  ],
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                          AnimatedSize(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            curve: Curves.easeOutCubic,
                                            alignment: Alignment.topLeft,
                                            child:
                                                ((movi['tagline']?.toString())
                                                        ?.isNotEmpty ??
                                                    false)
                                                ? Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 4,
                                                        ),
                                                    child: Text(
                                                      '"${movi['tagline']}"',
                                                      style: TextStyle(
                                                        color:
                                                            const Color(
                                                              0xFF00E5A0,
                                                            ).withValues(
                                                              alpha: 0.9,
                                                            ),
                                                        fontSize: 12,
                                                        fontStyle:
                                                            FontStyle.italic,
                                                        shadows: const [
                                                          Shadow(
                                                            color:
                                                                Colors.black87,
                                                            blurRadius: 4,
                                                            offset: Offset(
                                                              0,
                                                              1,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                          const SizedBox(height: 8),
                                          AnimatedSize(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            curve: Curves.easeOutCubic,
                                            alignment: Alignment.topLeft,
                                            child: Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                _buildRatingCapsule(
                                                  movi['vote_average'],
                                                  count: movi['vote_count'],
                                                ),
                                                if (_getYear(
                                                  movi['release_date'],
                                                ).isNotEmpty)
                                                  _buildMetaCapsule(
                                                    _getYear(
                                                      movi['release_date'],
                                                    ),
                                                    icon: Icons
                                                        .calendar_today_rounded,
                                                  ),
                                                if (_formatRuntime(
                                                  movi['runtime'],
                                                ).isNotEmpty)
                                                  _buildMetaCapsule(
                                                    _formatRuntime(
                                                      movi['runtime'],
                                                    ),
                                                    icon:
                                                        Icons.schedule_rounded,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // 2. Genre Pills, Trailer CTA & Action Dock
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Genre Pills
                        AnimatedSize(
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: genre.isNotEmpty
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      height: 32,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: genre.length,
                                        separatorBuilder: (context, index) =>
                                            const SizedBox(width: 8),
                                        itemBuilder: (context, index) {
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 13,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF161622),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                color: Colors.white.withValues(
                                                  alpha: 0.08,
                                                ),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(
                                                  width: 5,
                                                  height: 5,
                                                  decoration:
                                                      const BoxDecoration(
                                                        color: Color(
                                                          0xFF00E5A0,
                                                        ),
                                                        shape: BoxShape.circle,
                                                      ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  genre[index].toString(),
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),

                        const SizedBox(height: 18),

                        // Primary Watch Trailer Button
                        Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: videoLoading
                                ? null
                                : () async {
                                    setState(() {
                                      videoLoading = true;
                                    });
                                    await getVideo();
                                    if (!context.mounted) return;
                                    setState(() {
                                      videoLoading = false;
                                    });

                                    if (videoList.isNotEmpty) {
                                      showModalBottomSheet(
                                        context: context,
                                        isDismissible: true,
                                        enableDrag: true,
                                        isScrollControlled: true,
                                        backgroundColor: Colors.transparent,
                                        builder: (bottomSheetContext) {
                                          return MovieTrailerSheet(
                                            movieTitle:
                                                movi['title'] ??
                                                'Movie Trailer',
                                            videos: videoList,
                                            initialVideo: videos,
                                            formatDate: _formatDate,
                                          );
                                        },
                                      );
                                    }
                                  },
                            child: Ink(
                              width: double.infinity,
                              height: 52,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF00E5A0),
                                    Color(0xFF00C785),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFF00E5A0,
                                    ).withValues(alpha: 0.28),
                                    blurRadius: 14,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: videoLoading
                                    ? LoadingAnimationWidget.staggeredDotsWave(
                                        color: Colors.black,
                                        size: 26,
                                      )
                                    : const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.play_circle_fill_rounded,
                                            color: Colors.black,
                                            size: 22,
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Watch Trailer',
                                            style: TextStyle(
                                              color: Colors.black,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 14),

                        // Action Dock (My List, Rate, Share)
                        Row(
                          children: [
                            Expanded(
                              child: _buildActionTile(
                                icon: isFavorite
                                    ? Icons.bookmark_added_rounded
                                    : Icons.bookmark_add_outlined,
                                iconColor: isFavorite
                                    ? const Color(0xFF00E5A0)
                                    : Colors.white70,
                                label: isFavorite ? 'In List' : 'My List',
                                onTap: _toggleFavorite,
                                isLoading: isFavLoading,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildActionTile(
                                icon: userRating != null
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                iconColor: Colors.amber,
                                label: userRating != null
                                    ? '${(userRating! * 2).toStringAsFixed(1)} ★'
                                    : 'Rate',
                                onTap: _showRatingDialog,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildActionTile(
                                icon: Icons.share_rounded,
                                iconColor: Colors.white70,
                                label: 'Share',
                                onTap: _shareMovie,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // 6. Storyline / Synopsis Section
                SliverToBoxAdapter(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: ((movi['overview']?.toString())?.isNotEmpty ?? false)
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildSectionHeading('Storyline'),
                                const SizedBox(height: 10),
                                ReadMoreText(
                                  movi['overview'],
                                  trimLines: 4,
                                  trimMode: TrimMode.Line,
                                  trimCollapsedText: ' Read more',
                                  trimExpandedText: '  Show less',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.78),
                                    fontSize: 14.5,
                                    height: 1.6,
                                    letterSpacing: 0.2,
                                  ),
                                  moreStyle: const TextStyle(
                                    color: Color(0xFF00E5A0),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5,
                                  ),
                                  lessStyle: const TextStyle(
                                    color: Color(0xFF00E5A0),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),

                // 7. Key Details (2x2 Stats Grid)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeading('Details'),
                        const SizedBox(height: 12),
                        GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 2.3,
                          children: [
                            _buildDetailCard(
                              title: 'Status',
                              value: movi['status'] ?? 'Released',
                              icon: Icons.info_outline_rounded,
                            ),
                            _buildDetailCard(
                              title: 'Language',
                              value: (movi['original_language'] ?? 'en')
                                  .toString()
                                  .toUpperCase(),
                              icon: Icons.translate_rounded,
                            ),
                            _buildDetailCard(
                              title: 'Release Date',
                              value: _formatDate(movi['release_date']),
                              icon: Icons.calendar_today_rounded,
                            ),
                            _buildDetailCard(
                              title: 'Budget',
                              value: _formatCurrency(movi['budget']),
                              icon: Icons.monetization_on_outlined,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // 8. Top Cast Horizontal Section
                SliverToBoxAdapter(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: actors.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  child: _buildSectionHeading(
                                    'Top Cast',
                                    count: actors.length,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 168,
                                  child: ListView.separated(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                    ),
                                    scrollDirection: Axis.horizontal,
                                    itemCount: actors.length,
                                    separatorBuilder: (context, index) =>
                                        const SizedBox(width: 12),
                                    itemBuilder: (context, index) {
                                      final actor = actors[index];
                                      final profilePath = actor['profile_path'];
                                      final actorName =
                                          actor['name'] ?? 'Actor';
                                      final character =
                                          actor['character'] ?? '';

                                      return SizedBox(
                                        width: 95,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Container(
                                              width: 95,
                                              height: 115,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.08),
                                                ),
                                                color: const Color(0xFF161622),
                                              ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(13),
                                                child: profilePath != null
                                                    ? CachedNetworkImage(
                                                        imageUrl:
                                                            '${AppConstants.baseImageUrl}$profilePath',
                                                        fit: BoxFit.cover,
                                                        placeholder:
                                                            (
                                                              context,
                                                              url,
                                                            ) => Container(
                                                              color:
                                                                  const Color(
                                                                    0xFF161622,
                                                                  ),
                                                            ),
                                                        errorWidget:
                                                            (
                                                              context,
                                                              url,
                                                              error,
                                                            ) => const Center(
                                                              child: Icon(
                                                                Icons.person,
                                                                color: Colors
                                                                    .white24,
                                                                size: 36,
                                                              ),
                                                            ),
                                                      )
                                                    : const Center(
                                                        child: Icon(
                                                          Icons.person,
                                                          color: Colors.white24,
                                                          size: 36,
                                                        ),
                                                      ),
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              actorName,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (character.isNotEmpty)
                                              Text(
                                                character,
                                                style: TextStyle(
                                                  color: Colors.grey.shade400,
                                                  fontSize: 10.5,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),

                // 9. Reviews Section
                SliverToBoxAdapter(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeading(
                            'User Reviews',
                            count: reviews.length,
                          ),
                          const SizedBox(height: 12),
                          if (reviews.isNotEmpty)
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: reviews.length > 4
                                  ? 4
                                  : reviews.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final review = reviews[index];
                                final author = review['author'] ?? 'Anonymous';
                                final content = review['content'] ?? '';
                                final rating =
                                    (review['author_details']?['rating'] ?? 0) /
                                    2;
                                final date =
                                    (review['updated_at'] ??
                                            review['created_at'] ??
                                            '')
                                        .toString()
                                        .split('T')
                                        .first;

                                return Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF14141E),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.06,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 17,
                                            backgroundColor: const Color(
                                              0xFF00E5A0,
                                            ).withValues(alpha: 0.15),
                                            child: Text(
                                              author.isNotEmpty
                                                  ? author[0].toUpperCase()
                                                  : '?',
                                              style: const TextStyle(
                                                color: Color(0xFF00E5A0),
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  author,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 13,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                if (date.isNotEmpty)
                                                  Text(
                                                    date,
                                                    style: TextStyle(
                                                      color:
                                                          Colors.grey.shade500,
                                                      fontSize: 10.5,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (rating > 0)
                                            StarRating(
                                              size: 13,
                                              rating: rating.toDouble(),
                                              color: Colors.amber,
                                              borderColor: Colors.grey.shade700,
                                              allowHalfRating: true,
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      ReadMoreText(
                                        content,
                                        trimLines: 3,
                                        trimMode: TrimMode.Line,
                                        trimCollapsedText: ' Read more',
                                        trimExpandedText: ' Show less',
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.72,
                                          ),
                                          fontSize: 12.5,
                                          height: 1.5,
                                        ),
                                        moreStyle: const TextStyle(
                                          color: Color(0xFF00E5A0),
                                          fontWeight: FontWeight.bold,
                                        ),
                                        lessStyle: const TextStyle(
                                          color: Color(0xFF00E5A0),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFF14141E),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.05),
                                ),
                              ),
                              child: Column(
                                children: [
                                  const Icon(
                                    Icons.rate_review_outlined,
                                    color: Colors.white24,
                                    size: 34,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'No user reviews yet',
                                    style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 13,
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
              ],
            ),
    );
  }

  // ── Helper Widgets ──────────────────────────────────────────────────────────

  Widget _buildCircleNavButton({
    required IconData icon,
    required VoidCallback onPressed,
    Color color = Colors.white,
  }) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFF14141C).withValues(alpha: 0.75),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 18),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildMetaCapsule(String text, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRatingCapsule(dynamic rating, {dynamic count}) {
    final double score = (rating is num)
        ? rating.toDouble()
        : double.tryParse(rating?.toString() ?? '0') ?? 0.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 13, color: Colors.amber),
          const SizedBox(width: 3),
          Text(
            score > 0 ? score.toStringAsFixed(1) : 'NR',
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
    bool isLoading = false,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFF14141E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00E5A0),
                  ),
                )
              else
                Icon(icon, color: iconColor, size: 20),
              const SizedBox(height: 5),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeading(String title, {int? count}) {
    return Row(
      children: [
        Container(
          width: 3.5,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF00E5A0),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.2,
          ),
        ),
        if (count != null && count > 0) ...[
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDetailCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF14141E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF00E5A0), size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 10.5),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: Text(
                    value,
                    key: ValueKey(value),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernShimmer() {
    return Shimmer(
      direction: ShimmerDirection.ltr,
      period: const Duration(milliseconds: 1100),
      gradient: LinearGradient(
        colors: [
          const Color(0xFF14141E),
          const Color(0xFF222230),
          const Color(0xFF14141E),
        ],
        stops: const [0.0, 0.5, 1.0],
      ),
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 330,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.black),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 14,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Hero(
                          tag: 'movie_hero_${widget.movieId}',
                          child: Material(
                            type: MaterialType.transparency,
                            child: Container(
                              width: 96,
                              height: 140,
                              decoration: BoxDecoration(
                                color: const Color(0xFF222230),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  width: 1.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(13),
                                child: widget.posterPath != null
                                    ? CachedNetworkImage(
                                        imageUrl: imgUrl(widget.posterPath),
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) =>
                                            Container(
                                              color: const Color(0xFF181824),
                                            ),
                                        errorWidget: (context, url, error) =>
                                            Container(
                                              color: const Color(0xFF181824),
                                            ),
                                      )
                                    : Container(color: const Color(0xFF222230)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Hero(
                                tag: 'movie_title_${widget.movieId}',
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: widget.title != null
                                      ? Text(
                                          widget.title!,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.3,
                                            height: 1.2,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        )
                                      : Container(
                                          height: 22,
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF222230),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                height: 14,
                                width: 140,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF222230),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: List.generate(
                                  3,
                                  (index) => Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    height: 22,
                                    width: 45,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF222230),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: List.generate(
                      3,
                      (index) => Container(
                        margin: const EdgeInsets.only(right: 8),
                        height: 28,
                        width: 70,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    height: 52,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: List.generate(
                      3,
                      (index) => Expanded(
                        child: Container(
                          margin: EdgeInsets.only(right: index < 2 ? 10 : 0),
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    height: 18,
                    width: 100,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 14,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 14,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trailer Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class MovieTrailerSheet extends StatefulWidget {
  final String movieTitle;
  final List videos;
  final Map initialVideo;
  final String Function(dynamic) formatDate;

  const MovieTrailerSheet({
    super.key,
    required this.movieTitle,
    required this.videos,
    required this.initialVideo,
    required this.formatDate,
  });

  @override
  State<MovieTrailerSheet> createState() => _MovieTrailerSheetState();
}

class _MovieTrailerSheetState extends State<MovieTrailerSheet> {
  late YoutubePlayerController _ytController;
  late Map _currentVideo;
  bool _showForwardIndicator = false;
  bool _showRewindIndicator = false;
  Timer? _indicatorTimer;

  @override
  void initState() {
    super.initState();
    _currentVideo = widget.initialVideo;
    _ytController = YoutubePlayerController(
      initialVideoId: _currentVideo['key'] ?? '',
      flags: const YoutubePlayerFlags(
        autoPlay: true,
        forceHD: true,
        mute: false,
        enableCaption: false,
      ),
    );
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    _ytController.dispose();
    super.dispose();
  }

  void _seekRelative(int seconds) {
    final currentPosition = _ytController.value.position;
    final totalDuration = _ytController.metadata.duration;
    Duration newPosition;
    if (seconds > 0) {
      newPosition = currentPosition + Duration(seconds: seconds);
      if (totalDuration > Duration.zero && newPosition > totalDuration) {
        newPosition = totalDuration;
      }
      _showDoubleTapFeedback(forward: true);
    } else {
      newPosition = currentPosition + Duration(seconds: seconds);
      if (newPosition < Duration.zero) {
        newPosition = Duration.zero;
      }
      _showDoubleTapFeedback(forward: false);
    }
    _ytController.seekTo(newPosition);
  }

  void _showDoubleTapFeedback({required bool forward}) {
    _indicatorTimer?.cancel();
    setState(() {
      if (forward) {
        _showForwardIndicator = true;
        _showRewindIndicator = false;
      } else {
        _showRewindIndicator = true;
        _showForwardIndicator = false;
      }
    });

    _indicatorTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _showForwardIndicator = false;
          _showRewindIndicator = false;
        });
      }
    });
  }

  void _switchVideo(Map video) {
    if (_currentVideo['key'] == video['key']) return;
    setState(() {
      _currentVideo = video;
    });
    _ytController.load(video['key'] ?? '');
  }

  Future<void> _openInYouTube(String key) async {
    final uri = Uri.parse('https://www.youtube.com/watch?v=$key');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {}
  }

  Future<void> _openFullScreen() async {
    final currentPos = _ytController.value.position;
    final isPlaying = _ytController.value.isPlaying;
    _ytController.pause();

    final result = await Navigator.push<Duration>(
      context,
      PageRouteBuilder<Duration>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (context, animation, secondaryAnimation) {
          return LandscapeTrailerPlayer(
            videoId: _currentVideo['key'] ?? '',
            startAt: currentPos,
            heroTag: 'trailer_player_${widget.movieTitle}',
            title:
                '${widget.movieTitle} - ${_currentVideo['name'] ?? 'Trailer'}',
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOut,
            ),
            child: child,
          );
        },
      ),
    );

    if (result != null && mounted) {
      _ytController.seekTo(result);
      if (isPlaying) {
        _ytController.play();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141418),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.7),
            blurRadius: 30,
            spreadRadius: 10,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: bottomInset > 0 ? bottomInset : 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Drag Handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 42,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),

                // Sheet Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF00E5A0,
                                    ).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: const Color(
                                        0xFF00E5A0,
                                      ).withValues(alpha: 0.3),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 14,
                                        color: Color(0xFF00E5A0),
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        (_currentVideo['type'] ?? 'Trailer')
                                            .toString()
                                            .toUpperCase(),
                                        style: const TextStyle(
                                          color: Color(0xFF00E5A0),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.6,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_currentVideo['official'] == true) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'OFFICIAL',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              widget.movieTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // Quick Action: Open on YouTube
                      IconButton(
                        tooltip: 'Open in YouTube',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.07),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(
                          Icons.open_in_new_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                        onPressed: () =>
                            _openInYouTube(_currentVideo['key'] ?? ''),
                      ),
                      const SizedBox(width: 6),
                      // Close Button
                      IconButton(
                        tooltip: 'Close',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.07),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),

                // Video Player in 16:9 aspect ratio with Hero transition
                Hero(
                  tag: 'trailer_player_${widget.movieTitle}',
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              YoutubePlayer(
                                controller: _ytController,
                                showVideoProgressIndicator: true,
                                progressIndicatorColor: const Color(0xFF00E5A0),
                                progressColors: const ProgressBarColors(
                                  playedColor: Color(0xFF00E5A0),
                                  handleColor: Color(0xFF00E5A0),
                                  bufferedColor: Colors.white24,
                                  backgroundColor: Colors.white12,
                                ),
                                bottomActions: [
                                  CurrentPosition(),
                                  const SizedBox(width: 8),
                                  ProgressBar(
                                    isExpanded: true,
                                    colors: const ProgressBarColors(
                                      playedColor: Color(0xFF00E5A0),
                                      handleColor: Color(0xFF00E5A0),
                                      bufferedColor: Colors.white24,
                                      backgroundColor: Colors.white12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  RemainingDuration(),
                                  const PlaybackSpeedButton(),
                                  // Single Full Screen Button
                                  IconButton(
                                    icon: const Icon(
                                      Icons.fullscreen_rounded,
                                      color: Colors.white,
                                    ),
                                    tooltip: 'Full Screen',
                                    onPressed: _openFullScreen,
                                  ),
                                ],
                              ),

                              // Double tap zones: Left for -10s rewind, Right for +10s forward
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                bottom: 42,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onDoubleTap: () => _seekRelative(-10),
                                      ),
                                    ),
                                    Expanded(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onDoubleTap: () => _seekRelative(10),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Visual Ripple Feedback Overlay
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: Row(
                                    children: [
                                      // Left: Rewind 10s
                                      Expanded(
                                        child: AnimatedOpacity(
                                          opacity: _showRewindIndicator
                                              ? 1.0
                                              : 0.0,
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.5,
                                              ),
                                              borderRadius:
                                                  const BorderRadius.horizontal(
                                                    left: Radius.circular(16),
                                                    right: Radius.elliptical(
                                                      50,
                                                      100,
                                                    ),
                                                  ),
                                            ),
                                            child: const Center(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.fast_rewind_rounded,
                                                    color: Colors.white,
                                                    size: 34,
                                                  ),
                                                  SizedBox(height: 4),
                                                  Text(
                                                    '-10s',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      letterSpacing: 0.3,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Right: Forward 10s
                                      Expanded(
                                        child: AnimatedOpacity(
                                          opacity: _showForwardIndicator
                                              ? 1.0
                                              : 0.0,
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.5,
                                              ),
                                              borderRadius:
                                                  const BorderRadius.horizontal(
                                                    right: Radius.circular(16),
                                                    left: Radius.elliptical(
                                                      50,
                                                      100,
                                                    ),
                                                  ),
                                            ),
                                            child: const Center(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.fast_forward_rounded,
                                                    color: Colors.white,
                                                    size: 34,
                                                  ),
                                                  SizedBox(height: 4),
                                                  Text(
                                                    '+10s',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      letterSpacing: 0.3,
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Video Title & Published Info
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _currentVideo['name'] ?? 'Trailer',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_currentVideo['published_at'] != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                'Released: ${widget.formatDate(_currentVideo['published_at'])}',
                                style: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Multiple Videos Selection Chips
                if (widget.videos.length > 1) ...[
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Available Clips & Trailers (${widget.videos.length})',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.videos.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final item = widget.videos[index];
                        final isSelected = item['key'] == _currentVideo['key'];
                        final String label =
                            (item['name'] ??
                                    item['type'] ??
                                    'Video ${index + 1}')
                                .toString();

                        return InkWell(
                          onTap: () => _switchVideo(item),
                          borderRadius: BorderRadius.circular(20),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF00E5A0)
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF00E5A0)
                                    : Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.play_circle_fill_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 16,
                                  color: isSelected
                                      ? Colors.black
                                      : Colors.white70,
                                ),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 180,
                                  ),
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.black
                                          : Colors.white,
                                      fontSize: 12.5,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fullscreen Landscape Player
// ─────────────────────────────────────────────────────────────────────────────

class LandscapeTrailerPlayer extends StatefulWidget {
  final String videoId;
  final Duration startAt;
  final String title;
  final String heroTag;

  const LandscapeTrailerPlayer({
    super.key,
    required this.videoId,
    required this.startAt,
    required this.title,
    required this.heroTag,
  });

  @override
  State<LandscapeTrailerPlayer> createState() => _LandscapeTrailerPlayerState();
}

class _LandscapeTrailerPlayerState extends State<LandscapeTrailerPlayer> {
  late YoutubePlayerController _controller;
  bool _showForwardIndicator = false;
  bool _showRewindIndicator = false;
  Timer? _indicatorTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _controller = YoutubePlayerController(
      initialVideoId: widget.videoId,
      flags: YoutubePlayerFlags(
        autoPlay: true,
        forceHD: true,
        mute: false,
        startAt: widget.startAt.inSeconds,
      ),
    );
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    _controller.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _seekRelative(int seconds) {
    final currentPosition = _controller.value.position;
    final totalDuration = _controller.metadata.duration;
    Duration newPosition;
    if (seconds > 0) {
      newPosition = currentPosition + Duration(seconds: seconds);
      if (totalDuration > Duration.zero && newPosition > totalDuration) {
        newPosition = totalDuration;
      }
      _showDoubleTapFeedback(forward: true);
    } else {
      newPosition = currentPosition + Duration(seconds: seconds);
      if (newPosition < Duration.zero) {
        newPosition = Duration.zero;
      }
      _showDoubleTapFeedback(forward: false);
    }
    _controller.seekTo(newPosition);
  }

  void _showDoubleTapFeedback({required bool forward}) {
    _indicatorTimer?.cancel();
    setState(() {
      if (forward) {
        _showForwardIndicator = true;
        _showRewindIndicator = false;
      } else {
        _showRewindIndicator = true;
        _showForwardIndicator = false;
      }
    });

    _indicatorTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _showForwardIndicator = false;
          _showRewindIndicator = false;
        });
      }
    });
  }

  void _exitFullscreen() {
    Navigator.pop(context, _controller.value.position);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _exitFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Hero(
            tag: widget.heroTag,
            child: Material(
              color: Colors.transparent,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    YoutubePlayer(
                      controller: _controller,
                      showVideoProgressIndicator: true,
                      progressIndicatorColor: const Color(0xFF00E5A0),
                      progressColors: const ProgressBarColors(
                        playedColor: Color(0xFF00E5A0),
                        handleColor: Color(0xFF00E5A0),
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white12,
                      ),
                      topActions: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white,
                          ),
                          onPressed: _exitFullscreen,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      bottomActions: [
                        CurrentPosition(),
                        const SizedBox(width: 8),
                        ProgressBar(
                          isExpanded: true,
                          colors: const ProgressBarColors(
                            playedColor: Color(0xFF00E5A0),
                            handleColor: Color(0xFF00E5A0),
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        RemainingDuration(),
                        const PlaybackSpeedButton(),
                        IconButton(
                          icon: const Icon(
                            Icons.fullscreen_exit_rounded,
                            color: Colors.white,
                          ),
                          tooltip: 'Exit full screen',
                          onPressed: _exitFullscreen,
                        ),
                      ],
                    ),

                    // Double tap 10s seek: Left for -10s rewind, Right for +10s forward
                    Positioned(
                      top: 50,
                      left: 0,
                      right: 0,
                      bottom: 50,
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onDoubleTap: () => _seekRelative(-10),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onDoubleTap: () => _seekRelative(10),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Ripple indicator
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: true,
                        child: Row(
                          children: [
                            Expanded(
                              child: AnimatedOpacity(
                                opacity: _showRewindIndicator ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 180),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.5),
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(16),
                                      right: Radius.elliptical(50, 100),
                                    ),
                                  ),
                                  child: const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.fast_rewind_rounded,
                                          color: Colors.white,
                                          size: 40,
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          '-10s',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: AnimatedOpacity(
                                opacity: _showForwardIndicator ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 180),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.5),
                                    borderRadius: const BorderRadius.horizontal(
                                      right: Radius.circular(16),
                                      left: Radius.elliptical(50, 100),
                                    ),
                                  ),
                                  child: const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.fast_forward_rounded,
                                          color: Colors.white,
                                          size: 40,
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          '+10s',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
