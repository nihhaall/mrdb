import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rating/flutter_rating.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/services/movie_song_verifier.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/services/release_notification_service.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/widgets/image_gallery_viewer.dart';
import 'package:mrdb/widgets/mkv_stream_player_page.dart';
import 'package:mrdb/widgets/movie_share_card.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:readmore/readmore.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../../../constens/keys.dart';
import '../../../main.dart';
import '../../../provider/client.dart';
import '../../../provider/favorites_provider.dart';
import 'actor_preview_page.dart';

class MoviePreview extends StatefulWidget {
  final dynamic movieId;
  final Map<String, dynamic>? initialMovie;
  final String? posterPath;
  final String? title;
  final String? backdropPath;
  final List<String>? initialGenres;
  final String? subtitle;
  final String? heroTag;
  final String? titleHeroTag;

  const MoviePreview({
    super.key,
    required this.movieId,
    this.initialMovie,
    this.posterPath,
    this.title,
    this.backdropPath,
    this.initialGenres,
    this.subtitle,
    this.heroTag,
    this.titleHeroTag,
  });

  @override
  State<MoviePreview> createState() => _MoviePreviewState();
}

class _MoviePreviewState extends State<MoviePreview>
    with SingleTickerProviderStateMixin {
  final Random random = Random();
  bool islod = false;
  bool _detailsLoading = true;
  bool _isSlowConnection = false;
  NetworkFailureType _detailsFailureType = NetworkFailureType.none;
  String? _detailsErrorMessage;
  NetworkFailureType _videoFailureType = NetworkFailureType.none;
  bool videoLoading = false;
  double? userRating;
  Timer? _reconnectTimer;
  bool _isCheckingReconnect = false;
  int _imageRetryEpoch = 0;

  Map<String, dynamic> movi = {};
  Map<String, dynamic>? _collectionData;
  bool _isReminded = false;
  var genre = [];
  var actors = [];
  List<Map<String, dynamic>> _crewMembers = [];
  List<String> _galleryImages = [];
  List<Map<String, String>> _movieSongs = [];
  bool _songsLoading = false;
  bool _songsHasKey = true;
  String? _songsError;
  bool _songsLoadedOnce = false;
  List<TelegramVideoItem> _matchedBotVideos = [];
  bool _botVideosLoadedOnce = false;
  Map videos = {};
  List videoList = [];
  List reviews = [];

  YoutubePlayerController? _sliverYtController;
  bool _isPlayingInlineTrailer = false;
  bool _isClosingTrailer = false;
  bool _isScrollingToTopForTrailer = false;
  double _trailerCollapseScrollOffset = 140.0;
  double _defaultCollapseScrollOffset = 220.0;
  double _trailerDefaultHeightDelta = 0.0;
  late final ScrollController _scrollController;
  final ValueNotifier<bool> _isScrolledCollapsed = ValueNotifier<bool>(false);
  late final AnimationController _trailerHeightController;
  late final Animation<double> _trailerProgress;

  @override
  void initState() {
    super.initState();
    _trailerHeightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addListener(() {
        if (mounted) {
          setState(() {});
        }
      });
    _trailerProgress = CurvedAnimation(
      parent: _trailerHeightController,
      curve: Curves.easeInOutCubic,
    );
    _scrollController = ScrollController()
      ..addListener(() {
        if (!_scrollController.hasClients) return;
        if (_isPlayingInlineTrailer &&
            !_isClosingTrailer &&
            !_isScrollingToTopForTrailer &&
            _scrollController.offset >= _trailerCollapseScrollOffset) {
          _isClosingTrailer = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isPlayingInlineTrailer) {
              _pauseAndCollapseInlineTrailerFromScroll();
            }
          });
        }
        final collapsed =
            _scrollController.offset >
            (_isPlayingInlineTrailer
                ? _trailerCollapseScrollOffset
                : _defaultCollapseScrollOffset);
        if (_isScrolledCollapsed.value != collapsed) {
          _isScrolledCollapsed.value = collapsed;
        }
      });
    if (widget.initialMovie != null) {
      movi = Map<String, dynamic>.from(widget.initialMovie!);
      if (movi['title'] == null && movi['name'] != null) {
        movi['title'] = movi['name'];
      }
      // Ensure genre stays empty until getMovieDetails() fetches official TMDB genres
      genre = [];
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
    _checkRatingStatus();
    getVideo();
    SharedPreferences.getInstance().then((prefs) {
      final list = prefs.getStringList('movie_reminders') ?? [];
      if (list.contains(widget.movieId.toString()) && mounted) {
        setState(() => _isReminded = true);
      }
    });
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _trailerHeightController.dispose();
    _scrollController.dispose();
    _isScrolledCollapsed.dispose();
    _sliverYtController?.dispose();
    super.dispose();
  }

  void _startAutoReconnectIfNeeded() {
    if (_reconnectTimer?.isActive ?? false) return;
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final needsDetails = _detailsFailureType != NetworkFailureType.none;
      final needsVideo =
          videoList.isEmpty && _videoFailureType != NetworkFailureType.none;
      if (!needsDetails && !needsVideo) {
        timer.cancel();
        return;
      }
      if (_isCheckingReconnect || _detailsLoading) return;
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
          if (needsDetails) {
            getMovieDetails();
          }
          if (needsVideo) {
            getVideo();
          }
        }
      } finally {
        _isCheckingReconnect = false;
      }
    });
  }

  void _playInlineTrailer(String key) {
    if (key.isEmpty) return;
    _isClosingTrailer = false;
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _isScrollingToTopForTrailer = true;
      _scrollController
          .animateTo(
            0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (mounted) {
              _isScrollingToTopForTrailer = false;
            }
          });
    }
    if (_sliverYtController != null) {
      final ctrl = _sliverYtController!;
      final sameVideo =
          ctrl.metadata.videoId == key || ctrl.initialVideoId == key;
      if (sameVideo &&
          ctrl.value.isReady &&
          !ctrl.value.hasError &&
          ctrl.value.playerState == PlayerState.paused) {
        ctrl.play();
      } else {
        ctrl.load(key);
      }
    } else {
      _sliverYtController = YoutubePlayerController(
        initialVideoId: key,
        flags: const YoutubePlayerFlags(
          autoPlay: true,
          mute: false,
          forceHD: true,
          enableCaption: false,
          useHybridComposition: true,
        ),
      );
    }
    setState(() {
      _isPlayingInlineTrailer = true;
    });
    _trailerHeightController.forward();
  }

  void _stopInlineTrailer() {
    _isClosingTrailer = true;
    _isScrollingToTopForTrailer = false;
    _sliverYtController?.pause();
    _trailerHeightController.reverse().then((_) {
      if (mounted) {
        setState(() {
          _isPlayingInlineTrailer = false;
          _isClosingTrailer = false;
        });
      }
    });
  }

  /// Pauses the sliver trailer cleanly once scrolling pins the poster & title
  /// into the collapsed app bar, keeping the scroll position steady.
  void _pauseAndCollapseInlineTrailerFromScroll() {
    _sliverYtController?.pause();
    _trailerHeightController.value = 0.0;

    if (_scrollController.hasClients && _trailerDefaultHeightDelta != 0) {
      final pos = _scrollController.position;
      final maxPossible =
          pos.maxScrollExtent + max(0.0, _trailerDefaultHeightDelta);
      final targetOffset = (pos.pixels + _trailerDefaultHeightDelta).clamp(
        0.0,
        maxPossible,
      );
      if (pos.isScrollingNotifier.value || targetOffset > pos.maxScrollExtent) {
        pos.correctPixels(targetOffset);
      } else {
        _scrollController.jumpTo(targetOffset);
      }
    }

    setState(() {
      _isPlayingInlineTrailer = false;
      _isClosingTrailer = false;
    });
    final collapsed =
        (_scrollController.hasClients ? _scrollController.offset : 0.0) >
        _defaultCollapseScrollOffset;
    if (_isScrolledCollapsed.value != collapsed) {
      _isScrolledCollapsed.value = collapsed;
    }
  }

  Future<void> _handleTrailerTap() async {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
    if (videoLoading) return;
    if (videoList.isEmpty) {
      setState(() => videoLoading = true);
      await getVideo();
      if (!mounted) return;
      setState(() => videoLoading = false);
    }

    if (videoList.isNotEmpty) {
      final hasNet = await NetworkService.instance.hasInternet();
      if (!mounted) return;
      if (!hasNet) {
        showScaffoldMsg(
          context,
          txt: 'No internet connection to play trailer',
        );
        return;
      }
      final key = (videos['key'] ?? videoList.first['key'] ?? '').toString();
      if (key.isNotEmpty) {
        _playInlineTrailer(key);
      } else {
        _showNoTrailerSheet(movi['title'] ?? widget.title ?? 'Movie');
      }
    } else if (_videoFailureType == NetworkFailureType.noInternet) {
      showScaffoldMsg(
        context,
        txt: 'No internet connection. Connect and try again.',
      );
    } else if (_videoFailureType == NetworkFailureType.slowOrTimeout) {
      showScaffoldMsg(
        context,
        txt: 'Connection is too slow to load trailer. Try again.',
      );
    } else {
      _showNoTrailerSheet(movi['title'] ?? widget.title ?? 'Movie');
    }
  }

  Future<void> _openFullScreenFromSliver() async {
    if (_sliverYtController == null) return;
    final currentPos = _sliverYtController!.value.position;
    final isPlaying = _sliverYtController!.value.isPlaying;
    _sliverYtController!.pause();

    final videoKey = (videos['key'] ?? '').toString();
    final result = await Navigator.push<Duration>(
      context,
      PageRouteBuilder<Duration>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (context, animation, secondaryAnimation) {
          return LandscapeTrailerPlayer(
            videoId: videoKey,
            startAt: currentPos,
            heroTag:
                'trailer_player_${movi['title'] ?? widget.title ?? 'Movie'}',
            title:
                '${movi['title'] ?? widget.title ?? 'Movie'} - ${videos['name'] ?? 'Trailer'}',
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
            child: child,
          );
        },
      ),
    );

    if (result != null && mounted) {
      _sliverYtController!.seekTo(result);
      if (isPlaying) {
        _sliverYtController!.play();
      }
    }
  }

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
          .get()
          .timeout(const Duration(seconds: 5));
      if (mounted && doc.exists && doc.data()?['rating'] != null) {
        setState(() {
          userRating = (doc.data()!['rating'] as num).toDouble();
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    HapticFeedback.lightImpact();
    final favProvider = Provider.of<FavoritesProvider>(context, listen: false);
    try {
      await favProvider.toggleFavorite(
        movieId: widget.movieId,
        title: movi['title'] ?? movi['name'] ?? widget.title ?? 'Movie',
        posterPath: movi['poster_path'] ?? widget.posterPath,
        backdropPath: movi['backdrop_path'] ?? widget.backdropPath,
        releaseDate: movi['release_date'] ?? '',
        rating: (movi['vote_average'] is num)
            ? (movi['vote_average'] as num).toDouble()
            : 0.0,
      );
    } catch (_) {
      if (mounted) {
        showScaffoldMsg(
          context,
          txt: 'Could not update My List. Check your internet connection.',
        );
      }
    }
  }

  bool _isUpcomingMovie() {
    final rd = (movi['release_date'] ?? widget.subtitle)?.toString();
    if (rd == null || rd.isEmpty) return false;
    try {
      final parsed = DateTime.parse(rd);
      return parsed.isAfter(DateTime.now());
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleReminder() async {
    HapticFeedback.mediumImpact();
    final idStr = widget.movieId.toString();
    final title = (movi['title'] ?? widget.title ?? 'Movie').toString();
    final releaseDateStr =
        (movi['release_date'] ?? widget.initialMovie?['release_date'])
            ?.toString();

    if (_isReminded) {
      await ReleaseNotificationService.instance.cancelMovieReminder(idStr);
      if (mounted) {
        setState(() => _isReminded = false);
        showScaffoldMsg(context, txt: 'Reminder removed for $title');
      }
    } else {
      final ok = await ReleaseNotificationService.instance
          .scheduleMovieReleaseReminder(
        movieId: idStr,
        movieTitle: title,
        releaseDateStr: releaseDateStr,
      );
      if (mounted) {
        setState(() => _isReminded = true);
        showScaffoldMsg(
          context,
          txt: ok
              ? 'Release notification scheduled for $title!'
              : 'Reminder saved! Enable notifications in Settings for alerts.',
        );
      }
    }
  }

  Future<void> _shareVisualCard(
    GlobalKey cardKey,
    String title,
    String shareText,
  ) async {
    try {
      final boundary =
          cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final dir = await getTemporaryDirectory();
      final safeName = title.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final file = File('${dir.path}/mrdb_${safeName}_card.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: shareText,
        ),
      );
    } catch (e) {
      debugPrint('Visual share card error: $e');
      if (mounted) {
        showScaffoldMsg(context, txt: 'Could not generate card image.');
      }
    }
  }

  void _shareMovie() {
    HapticFeedback.lightImpact();
    final title = (movi['title'] ?? widget.title ?? 'Movie').toString();
    final year = movi['release_date']?.toString().split('-').first ?? '';
    final rating = movi['vote_average'] != null
        ? '${(movi['vote_average'] as num).toStringAsFixed(1)}/10'
        : '';
    final videoKey =
        videos['key'] ?? (videoList.isNotEmpty ? videoList.first['key'] : null);
    final trailerUrl = videoKey != null
        ? 'https://youtu.be/$videoKey'
        : 'https://www.themoviedb.org/movie/${widget.movieId}';
    final shareText =
        'Check out "$title" ($year) on MRDb!\nRating: $rating ★\nWatch Trailer: $trailerUrl';

    final posterPath = movi['poster_path'] ?? widget.posterPath;
    final backdropPath = movi['backdrop_path'] ?? widget.backdropPath;
    final posterUrl = posterPath != null
        ? '${AppConstants.baseImageUrl}$posterPath'
        : '';
    final backdropUrl = backdropPath != null
        ? '${AppConstants.baseImageUrl}$backdropPath'
        : '';
    final genreNames = genre.map((e) => e.toString()).toList();
    final GlobalKey cardBoundaryKey = GlobalKey();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141620),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        side: BorderSide(color: Color(0xFF222636)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Share Movie Card',
                    style: TextStyle(
                      color: Color(0xFFE6EDF3),
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white54,
                      size: 20,
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: RepaintBoundary(
                  key: cardBoundaryKey,
                  child: MovieShareCard(
                    title: title,
                    year: year,
                    rating: rating,
                    tagline: movi['tagline']?.toString(),
                    genres: genreNames,
                    posterUrl: posterUrl,
                    backdropUrl: backdropUrl,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await _shareVisualCard(
                      cardBoundaryKey,
                      title,
                      shareText,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.image_rounded, size: 18),
                  label: const Text(
                    'Share Visual Card Image',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5A0),
                    foregroundColor: const Color(0xFF0A0D14),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Amicons.remix_whatsapp,
                    color: Color(0xFF25D366),
                    size: 22,
                  ),
                ),
                title: const Text(
                  'Share Text to WhatsApp',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  'Send trailer & details directly',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final uri = Uri.parse(
                    'whatsapp://send?text=${Uri.encodeComponent(shareText)}',
                  );
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  } else {
                    Clipboard.setData(ClipboardData(text: shareText));
                    if (mounted) {
                      showScaffoldMsg(
                        context,
                        txt: 'Recommendation copied to clipboard',
                      );
                    }
                  }
                },
              ),
              const Divider(color: Color(0xFF1F2432)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5A0).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.copy_rounded,
                    color: Color(0xFF00E5A0),
                    size: 22,
                  ),
                ),
                title: const Text(
                  'Copy Recommendation',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  'Copy formatted title, rating & trailer link',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: shareText));
                  showScaffoldMsg(context, txt: 'Copied to clipboard!');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _fetchCollection(int collectionId) async {
    try {
      final data = await NetworkService.instance.getTmdbJson(
        '/3/collection/$collectionId?api_key=${AppConstants.apiKey}&language=en',
        timeout: const Duration(seconds: 10),
        maxAttempts: 1,
      );
      if (data is Map<String, dynamic> && mounted) {
        setState(() {
          _collectionData = data;
        });
      }
    } catch (e) {
      debugPrint('Collection fetch error: $e');
    }
  }

  Widget _buildCollectionSection() {
    if (_collectionData == null || _collectionData!['parts'] == null) {
      return const SizedBox.shrink();
    }
    final List parts = (_collectionData!['parts'] as List)
        .where((p) => p['id'] != widget.movieId)
        .toList();
    if (parts.isEmpty) return const SizedBox.shrink();

    final collectionName = _collectionData!['name'] ?? 'Franchise';

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_rounded, color: Color(0xFFFF9F1C), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'More from $collectionName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              scrollDirection: Axis.horizontal,
              itemCount: parts.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final movie = parts[index];
                final poster = movie['poster_path']?.toString().trim();
                final hasPoster =
                    poster != null && poster.isNotEmpty && poster != 'null';
                final title = movie['title'] ?? 'Movie';
                final year = movie['release_date']?.toString().split('-').first ?? '';

                Widget buildPosterFallback() => Container(
                      width: 105,
                      height: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E2230),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.movie_outlined,
                            color: Colors.white30,
                            size: 30,
                          ),
                          SizedBox(height: 6),
                          Text(
                            'No Poster',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    );

                return InkWell(
                  borderRadius: BorderRadius.circular(12),
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
                          backdropPath: movie['backdrop_path'],
                          subtitle: year,
                          heroTag: 'collection_movie_${movie['id']}',
                        ),
                      ),
                    );
                  },
                  child: SizedBox(
                    width: 105,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Hero(
                            tag: 'collection_movie_${movie['id']}',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: hasPoster
                                  ? CachedNetworkImage(
                                      imageUrl: '${AppConstants.baseImageUrl}$poster',
                                      fit: BoxFit.cover,
                                      width: 105,
                                      height: double.infinity,
                                      placeholder: (context, url) => Container(
                                        width: 105,
                                        height: double.infinity,
                                        color: const Color(0xFF1E2230),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          buildPosterFallback(),
                                    )
                                  : buildPosterFallback(),
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
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (year.isNotEmpty)
                          Text(
                            year,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
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
      ),
    );
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
                            })
                            .timeout(const Duration(seconds: 4));
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
    final detailsPath =
        '/3/movie/${widget.movieId}?api_key=${AppConstants.apiKey}&language=en&append_to_response=release_dates,translations,watch/providers,images&include_image_language=en,null';
    final castPath =
        '/3/movie/${widget.movieId}/credits?api_key=${AppConstants.apiKey}&language=en';

    if (mounted) {
      setState(() {
        _detailsLoading = true;
        _isSlowConnection = false;
        _detailsFailureType = NetworkFailureType.none;
        _detailsErrorMessage = null;
        if (movi.isEmpty) {
          islod = true;
        }
      });
    }

    final hasNet = await NetworkService.instance.hasInternet();
    if (!hasNet) {
      if (mounted) {
        setState(() {
          islod = false;
          _detailsLoading = false;
          _isSlowConnection = false;
          _detailsFailureType = NetworkFailureType.noInternet;
          _detailsErrorMessage =
              'No internet connection. Please turn on Wi-Fi or mobile data.';
        });
        _startAutoReconnectIfNeeded();
      }
      return;
    }

    void markSlow() {
      if (mounted && _detailsLoading && !_isSlowConnection) {
        setState(() => _isSlowConnection = true);
      }
    }

    try {
      final responses = await Future.wait([
        NetworkService.instance.getTmdbJson(
          detailsPath,
          timeout: const Duration(seconds: 12),
          onSlowConnection: markSlow,
        ),
        NetworkService.instance.getTmdbJson(
          castPath,
          timeout: const Duration(seconds: 12),
          onSlowConnection: markSlow,
        ),
      ]);

      if (responses[0] is Map) {
        final Map<String, dynamic> response = Map<String, dynamic>.from(
          responses[0] as Map,
        );
        var genresList = response['genres'] as List? ?? [];
        final fetchedGenres = genresList
            .map((item) => item['name'].toString())
            .toList();

        // Extract HD backdrops & posters for Gallery
        final imagesMap = response['images'] as Map? ?? {};
        final backdrops = (imagesMap['backdrops'] as List? ?? [])
            .map((e) => e is Map ? e['file_path']?.toString() : null)
            .whereType<String>()
            .where((p) => p.isNotEmpty);
        final posters = (imagesMap['posters'] as List? ?? [])
            .map((e) => e is Map ? e['file_path']?.toString() : null)
            .whereType<String>()
            .where((p) => p.isNotEmpty);
        final gallerySet = <String>{
          if (response['backdrop_path'] != null)
            response['backdrop_path'].toString(),
          ...backdrops.take(14),
          ...posters.take(6),
        };

        if (mounted) {
          _reconnectTimer?.cancel();
          setState(() {
            movi = {...movi, ...response};
            if (fetchedGenres.isNotEmpty) {
              genre = fetchedGenres;
            }
            _galleryImages = gallerySet.toList();
            islod = false;
            _detailsLoading = false;
            _isSlowConnection = false;
            _detailsFailureType = NetworkFailureType.none;
            _detailsErrorMessage = null;
          });
          if (response['belongs_to_collection'] != null &&
              response['belongs_to_collection']['id'] != null) {
            _fetchCollection(response['belongs_to_collection']['id']);
          }
        }
      }

      if (responses[1] is Map) {
        final castResponse = responses[1] as Map;
        List allCast = castResponse['cast'] as List? ?? [];
        final fetchedActors = allCast
            .where((element) => element['known_for_department'] == 'Acting')
            .toList();

        // Extract key Director & Crew members (deduplicated per person)
        final rawCrew = castResponse['crew'] as List? ?? [];
        const priorityJobs = <String, int>{
          'Director': 0,
          'Screenplay': 1,
          'Writer': 2,
          'Story': 3,
          'Original Music Composer': 4,
          'Director of Photography': 5,
          'Producer': 6,
        };
        final Map<dynamic, Map<String, dynamic>> crewById = {};
        for (final member in rawCrew) {
          if (member is! Map) continue;
          final job = (member['job'] ?? '').toString();
          if (!priorityJobs.containsKey(job) || member['id'] == null) continue;
          final pid = member['id'];
          if (crewById.containsKey(pid)) {
            final existingRoles = crewById[pid]!['roles'] as List<String>;
            if (!existingRoles.contains(job)) existingRoles.add(job);
            final currentBest = crewById[pid]!['priority'] as int;
            if (priorityJobs[job]! < currentBest) {
              crewById[pid]!['priority'] = priorityJobs[job]!;
            }
          } else {
            crewById[pid] = {
              'id': pid,
              'name': member['name'] ?? 'Crew',
              'profile_path': member['profile_path'],
              'roles': <String>[job],
              'priority': priorityJobs[job]!,
            };
          }
        }
        final sortedCrew = crewById.values.toList()
          ..sort(
            (a, b) => (a['priority'] as int).compareTo(b['priority'] as int),
          );

        if (mounted) {
          setState(() {
            actors = fetchedActors;
            _crewMembers = sortedCrew;
          });
        }
      }

      // Fetch reviews, songs, and matched bot videos asynchronously in background
      getReviews();
      if (!_songsLoadedOnce) {
        _fetchMovieSongs();
      }
      if (!_botVideosLoadedOnce) {
        _fetchMatchingBotVideos();
      }
    } catch (e) {
      final classified = await NetworkService.instance.classifyError(e);
      if (mounted) {
        setState(() {
          islod = false;
          _detailsLoading = false;
          _isSlowConnection = false;
          _detailsFailureType = classified.type;
          _detailsErrorMessage = classified.message;
        });
        _startAutoReconnectIfNeeded();
      }
    }
  }

  Future<void> _fetchMatchingBotVideos() async {
    final tmdbId = int.tryParse(widget.movieId.toString());
    if (tmdbId == null) return;
    _botVideosLoadedOnce = true;
    try {
      final result = await TelegramStreamService.instance.fetchBotVideos(
        tmdbId: tmdbId,
        limit: 10,
      );
      if (mounted && result.videos.isNotEmpty) {
        setState(() {
          _matchedBotVideos = result.videos;
        });
      }
    } catch (_) {}
  }

  String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  Future<String> _resolveYouTubeApiKey() async {
    final local = AppConstants.youtubeApiKey.trim();
    if (local.isNotEmpty) return local;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('keys')
          .get()
          .timeout(const Duration(seconds: 3));
      if (doc.exists) {
        final remote = doc.data()?['youtubeApiKey']?.toString().trim() ?? '';
        if (remote.isNotEmpty) return remote;
      }
    } catch (_) {}
    return '';
  }

  Future<void> _fetchMovieSongs() async {
    final title = (movi['title'] ?? movi['name'] ?? widget.title ?? '')
        .toString()
        .trim();
    if (title.isEmpty) return;

    _songsLoadedOnce = true;
    if (mounted) {
      setState(() {
        _songsLoading = true;
        _songsError = null;
      });
    }

    final ytKey = await _resolveYouTubeApiKey();
    if (ytKey.isEmpty) {
      if (mounted) {
        setState(() {
          _songsLoading = false;
          _songsHasKey = false;
        });
      }
      return;
    }

    if (!await NetworkService.instance.hasInternet()) {
      if (mounted) {
        setState(() {
          _songsLoading = false;
          _songsHasKey = true;
          _songsError = 'No internet connection';
        });
      }
      return;
    }

    final yearStr =
        (movi['release_date'] ?? movi['first_air_date'] ?? '')
            .toString()
            .split('-')
            .first
            .trim();
    final releaseYear = int.tryParse(yearStr);
    final originalTitle =
        (movi['original_title'] ?? movi['original_name'] ?? '')
            .toString()
            .trim();
    final composers = _crewMembers
        .where(
          (m) => (m['roles'] as List?)?.contains('Original Music Composer') ??
              false,
        )
        .map((m) => (m['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
    final directors = _crewMembers
        .where((m) => (m['roles'] as List?)?.contains('Director') ?? false)
        .map((m) => (m['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
    final castNames = actors
        .whereType<Map>()
        .take(6)
        .map((a) => (a['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();

    final songCtx = MovieSongContext(
      title: title,
      originalTitle: originalTitle,
      releaseYear: releaseYear,
      composers: composers,
      directors: directors,
      castNames: castNames,
    );
    final query = MovieSongVerifier.buildSearchQuery(songCtx);
    final searchUri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/search'
      '?part=snippet'
      '&type=video'
      '&videoEmbeddable=true'
      '&safeSearch=moderate'
      '&maxResults=15'
      '&q=${Uri.encodeComponent(query)}'
      '&key=$ytKey',
    );

    try {
      final res = await NetworkService.instance.client
          .get(searchUri)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final searchItems = data['items'] as List? ?? [];
        final searchFallbackById = <String, MovieSongCandidate>{};
        final orderedIds = <String>[];

        for (final item in searchItems) {
          if (item is! Map) continue;
          final idMap = item['id'] as Map?;
          final snippet = item['snippet'] as Map?;
          final videoId = idMap?['videoId']?.toString() ?? '';
          if (videoId.isEmpty || searchFallbackById.containsKey(videoId)) {
            continue;
          }
          orderedIds.add(videoId);
          searchFallbackById[videoId] = MovieSongCandidate(
            videoId: videoId,
            title: _decodeHtmlEntities(
              (snippet?['title'] ?? 'Song').toString(),
            ),
            description: _decodeHtmlEntities(
              (snippet?['description'] ?? '').toString(),
            ),
            channelTitle: _decodeHtmlEntities(
              (snippet?['channelTitle'] ?? '').toString(),
            ),
            thumbUrl: MovieSongVerifier.pickThumbnail(snippet, videoId),
            publishedAt: DateTime.tryParse(
              (snippet?['publishedAt'] ?? '').toString(),
            ),
          );
        }

        final candidates = <MovieSongCandidate>[];
        if (orderedIds.isNotEmpty) {
          final detailedById = <String, MovieSongCandidate>{};
          try {
            final videosUri = Uri.parse(
              'https://www.googleapis.com/youtube/v3/videos'
              '?part=snippet,contentDetails,status'
              '&id=${Uri.encodeComponent(orderedIds.join(','))}'
              '&key=$ytKey',
            );
            final detailsRes = await NetworkService.instance.client
                .get(videosUri)
                .timeout(const Duration(seconds: 8));
            if (detailsRes.statusCode == 200) {
              final detailsData =
                  jsonDecode(detailsRes.body) as Map<String, dynamic>;
              for (final raw in detailsData['items'] as List? ?? []) {
                if (raw is! Map) continue;
                final id = raw['id']?.toString() ?? '';
                if (id.isEmpty) continue;
                final snippet = raw['snippet'] as Map? ?? {};
                final contentDetails = raw['contentDetails'] as Map? ?? {};
                final status = raw['status'] as Map? ?? {};
                final rawTags = snippet['tags'] as List? ?? [];
                detailedById[id] = MovieSongCandidate(
                  videoId: id,
                  title: _decodeHtmlEntities(
                    (snippet['title'] ?? 'Song').toString(),
                  ),
                  description: _decodeHtmlEntities(
                    (snippet['description'] ?? '').toString(),
                  ),
                  channelTitle: _decodeHtmlEntities(
                    (snippet['channelTitle'] ?? '').toString(),
                  ),
                  tags: rawTags.map((t) => _decodeHtmlEntities(t.toString())).toList(),
                  categoryId: (snippet['categoryId'] ?? '').toString(),
                  thumbUrl: MovieSongVerifier.pickThumbnail(snippet, id),
                  publishedAt: DateTime.tryParse(
                    (snippet['publishedAt'] ?? '').toString(),
                  ),
                  durationSeconds: MovieSongVerifier.parseIsoDurationSeconds(
                    contentDetails['duration']?.toString(),
                  ),
                  embeddable: status['embeddable'] != false,
                );
              }
            }
          } catch (_) {
            // Fall back to search snippet metadata if video enrichment fails
          }

          for (final id in orderedIds) {
            final c = detailedById[id] ?? searchFallbackById[id];
            if (c != null) candidates.add(c);
          }
        }

        final verified = MovieSongVerifier.filterAndRank(candidates, songCtx);
        if (mounted) {
          setState(() {
            _movieSongs = verified;
            _songsLoading = false;
            _songsHasKey = true;
            _songsError = null;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _songsLoading = false;
            _songsHasKey = true;
            _songsError = 'Could not load songs (HTTP ${res.statusCode})';
          });
        }
      }
    } catch (e) {
      final classified = await NetworkService.instance.classifyError(e);
      if (mounted) {
        setState(() {
          _songsLoading = false;
          _songsHasKey = true;
          _songsError = classified.message;
        });
      }
    }
  }

  Future<void> getReviews() async {
    try {
      final data = await NetworkService.instance.getTmdbJson(
        '/3/movie/${widget.movieId}/reviews?api_key=${AppConstants.apiKey}',
        timeout: const Duration(seconds: 12),
        maxAttempts: 2,
      );
      if (data is Map && mounted) {
        setState(() {
          reviews = data['results'] ?? [];
        });
      }
    } catch (_) {}
  }

  Future<void> _searchYouTube(String query) async {
    final uri = Uri.parse(
      'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}',
    );
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {}
  }

  void _showNoTrailerSheet(String movieTitle) {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetContext) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          decoration: BoxDecoration(
            color: const Color(0xFF161822),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.1),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.redAccent,
                  size: 38,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Trailer Not Found on TMDB',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'No direct video link on TMDB yet. Watch the official trailer for "$movieTitle" directly on YouTube.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey.shade400,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(bottomSheetContext);
                    _searchYouTube('$movieTitle official trailer');
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text(
                    'Search & Watch on YouTube',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> getVideo() async {
    final origLang =
        (movi['original_language'] ??
                widget.initialMovie?['original_language'] ??
                '')
            .toString()
            .trim();
    final languages = {
      'en',
      'null',
      if (origLang.isNotEmpty) origLang,
      'ml',
      'hi',
      'ta',
      'te',
      'kn',
      'bn',
      'mr',
      'pa',
      'es',
      'fr',
      'de',
      'ja',
      'ko',
      'zh',
      'it',
    }.join(',');

    try {
      _videoFailureType = NetworkFailureType.none;
      final data = await NetworkService.instance.getTmdbJson(
        '/3/movie/${widget.movieId}/videos?api_key=${AppConstants.apiKey}&include_video_language=$languages',
        timeout: const Duration(seconds: 12),
        maxAttempts: 2,
      );
      if (data is Map) {
        var jsonDe = data['results'] as List? ?? [];
        var filtered = jsonDe
            .where(
              (element) =>
                  element is Map &&
                  element['site'] == 'YouTube' &&
                  element['key'] != null &&
                  (element['key'] as String).isNotEmpty,
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
              if (type == 'Clip') return 4;
              return 5;
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
            setState(() {
              videoList = [];
              videos = {};
            });
          }
          return;
        }
      }
    } catch (e) {
      final classified = await NetworkService.instance.classifyError(e);
      _videoFailureType = classified.type;
      if (mounted) {
        _startAutoReconnectIfNeeded();
      }
    }
  }

  static const Map<String, String> _languageNames = {
    'en': 'English',
    'hi': 'Hindi',
    'te': 'Telugu',
    'ta': 'Tamil',
    'ml': 'Malayalam',
    'kn': 'Kannada',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ar': 'Arabic',
    'bn': 'Bengali',
    'mr': 'Marathi',
    'pa': 'Punjabi',
    'gu': 'Gujarati',
    'ur': 'Urdu',
    'th': 'Thai',
    'id': 'Indonesian',
    'tr': 'Turkish',
    'vi': 'Vietnamese',
  };

  String _getLanguageName(String code) {
    final clean = code.toLowerCase().trim();
    return _languageNames[clean] ?? clean.toUpperCase();
  }

  /// Extracts theatrical release date, OTT / Digital release date, and platform name
  Map<String, String?> _extractReleaseDates() {
    // Authoritative primary release date (exact same date as shown on home card)
    final rawTheatrical =
        movi['release_date'] ?? widget.initialMovie?['release_date'];
    final String? theatricalDate =
        (rawTheatrical != null && rawTheatrical.toString().isNotEmpty)
        ? rawTheatrical.toString()
        : null;

    String? digitalDate;

    if (movi['release_dates'] is Map &&
        movi['release_dates']['results'] is List) {
      final List results = movi['release_dates']['results'];
      final prioritizedCountries = ['IN', 'US', 'GB', 'CA', 'AU'];

      for (final countryCode in prioritizedCountries) {
        if (digitalDate != null) break;
        final countryData = results.firstWhere(
          (c) => c is Map && c['iso_3166_1'] == countryCode,
          orElse: () => null,
        );
        if (countryData != null && countryData['release_dates'] is List) {
          for (final rd in countryData['release_dates']) {
            if (rd['type'] == 4) {
              final dateStr = rd['release_date']?.toString();
              if (dateStr != null && dateStr.isNotEmpty) {
                digitalDate = dateStr;
                break;
              }
            }
          }
        }
      }

      if (digitalDate == null) {
        for (final c in results) {
          if (c is Map && c['release_dates'] is List) {
            for (final rd in c['release_dates']) {
              if (rd['type'] == 4) {
                final dateStr = rd['release_date']?.toString();
                if (dateStr != null && dateStr.isNotEmpty) {
                  digitalDate = dateStr;
                  break;
                }
              }
            }
          }
          if (digitalDate != null) break;
        }
      }
    }

    return {'theatrical': theatricalDate, 'digital': digitalDate};
  }

  /// Extracts available OTT streaming platforms (with logo and name)
  List<Map<String, String>> _extractOttPlatforms() {
    final List<Map<String, String>> platforms = [];
    final Set<String> seenNames = {};

    // 1. From watch/providers (flatrate streaming)
    if (movi['watch/providers'] is Map &&
        movi['watch/providers']['results'] is Map) {
      final wpResults = movi['watch/providers']['results'] as Map;
      // Prioritize user region (India, US, Global)
      for (final cc in ['IN', 'US', 'GB']) {
        if (wpResults[cc] is Map && wpResults[cc]['flatrate'] is List) {
          for (final item in wpResults[cc]['flatrate']) {
            if (item is Map) {
              final name = item['provider_name']?.toString() ?? '';
              final logo = item['logo_path']?.toString() ?? '';
              if (name.isNotEmpty && !seenNames.contains(name.toLowerCase())) {
                seenNames.add(name.toLowerCase());
                platforms.add({'name': name, 'logo': logo});
              }
            }
          }
        }
      }
    }

    // 2. From release_dates notes (e.g. Netflix, Paramount+, ZEE5)
    if (movi['release_dates'] is Map &&
        movi['release_dates']['results'] is List) {
      for (final c in movi['release_dates']['results']) {
        if (c is Map && c['release_dates'] is List) {
          for (final rd in c['release_dates']) {
            if (rd['type'] == 4) {
              final note = rd['note']?.toString().trim() ?? '';
              if (note.isNotEmpty &&
                  !note.toLowerCase().contains('digital') &&
                  !note.toLowerCase().contains('4k') &&
                  !seenNames.contains(note.toLowerCase())) {
                seenNames.add(note.toLowerCase());
                platforms.add({'name': note, 'logo': ''});
              }
            }
          }
        }
      }
    }

    return platforms;
  }

  /// Extracts the authentic original language of the movie
  String _extractOriginalLanguage() {
    final origCode = (movi['original_language'] ?? 'en')
        .toString()
        .toLowerCase();
    return _getLanguageName(origCode);
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

  String _getDateBadgeText(dynamic dateStr) {
    if (dateStr == null) return '';
    try {
      final date = DateTime.tryParse(dateStr.toString());
      if (date != null) {
        if (date.isAfter(DateTime.now())) {
          return _formatDate(dateStr);
        }
        return date.year.toString();
      }
    } catch (_) {}
    return _getYear(dateStr);
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
    final favProvider = Provider.of<FavoritesProvider>(context);
    final isFavorite = favProvider.isLiked(widget.movieId);
    final isFavLoading = favProvider.isMovieLoading(widget.movieId);

    final backdropPath = movi['backdrop_path'] ?? movi['poster_path'];
    final backdrop = imgUrl(backdropPath);
    final poster = imgUrl(
      movi['poster_path'] ??
          widget.posterPath ??
          movi['backdrop_path'] ??
          widget.backdropPath,
    );
    final year = _getDateBadgeText(movi['release_date']);

    final mediaQuery = MediaQuery.of(context);
    final statusBarHeight = mediaQuery.padding.top;
    final screenWidth = mediaQuery.size.width;
    final playerExpandedHeight = statusBarHeight + (screenWidth * 9 / 16);
    final pinnedToolbarHeight = kToolbarHeight + statusBarHeight;
    final defaultExpandedHeight = 330.0.clamp(pinnedToolbarHeight + 10, 400.0);
    final clampedPlayerHeight = playerExpandedHeight.clamp(
      pinnedToolbarHeight + 10,
      400.0,
    );
    _trailerCollapseScrollOffset = (clampedPlayerHeight -
            pinnedToolbarHeight -
            2.0)
        .clamp(24.0, 350.0);
    _defaultCollapseScrollOffset = (defaultExpandedHeight -
            pinnedToolbarHeight -
            25.0)
        .clamp(80.0, 350.0);
    _trailerDefaultHeightDelta = defaultExpandedHeight - clampedPlayerHeight;

    return PopScope(
      canPop: !_isPlayingInlineTrailer && _trailerProgress.value == 0.0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isPlayingInlineTrailer || _trailerProgress.value > 0.0) {
          _stopInlineTrailer();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D14),
        body: islod
            ? Column(
                children: [
                  if (_isSlowConnection)
                    const SafeArea(
                      bottom: false,
                      child: NetworkStatusBanner(
                        isSlow: true,
                        message:
                            'Slow connection — loading movie details...',
                      ),
                    ),
                  Expanded(child: _buildModernShimmer()),
                ],
              )
            : (_detailsFailureType != NetworkFailureType.none && movi.isEmpty
                ? SafeArea(
                    child: Column(
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: _buildCircleNavButton(
                              icon: Icons.arrow_back_ios_new_rounded,
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                        Expanded(
                          child: NetworkStateView(
                            failureType: _detailsFailureType,
                            customMessage: _detailsErrorMessage,
                            onRetry: () {
                              getMovieDetails();
                              getVideo();
                            },
                          ),
                        ),
                      ],
                    ),
                  )
                : CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // 1. Cinematic Hero Header with Poster & Title in front of the Sliver
                  SliverAppBar(
                    backgroundColor: const Color(0xFF0D0D14),
                    pinned: true,
                    elevation: 0,
                    expandedHeight: (ui.lerpDouble(
                      330.0,
                      playerExpandedHeight,
                      _trailerProgress.value,
                    ) ?? 330.0)
                        .clamp(kToolbarHeight + statusBarHeight + 10, 400.0),
                    leadingWidth: 56,
                    leading: Opacity(
                      opacity: (1.0 - _trailerProgress.value).clamp(0.0, 1.0),
                      child: IgnorePointer(
                        ignoring: _trailerProgress.value > 0.05,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Center(
                            child: _buildCircleNavButton(
                              icon: Icons.arrow_back_ios_new_rounded,
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                    actions: [
                      ValueListenableBuilder<bool>(
                        valueListenable: _isScrolledCollapsed,
                        builder: (context, isCollapsed, _) {
                          final showAction =
                              isCollapsed && _trailerProgress.value < 0.1;
                          return Opacity(
                            opacity: showAction ? 1.0 : 0.0,
                            child: IgnorePointer(
                              ignoring: !showAction,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 12.0),
                                child: Center(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: _handleTrailerTap,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF14141C,
                                          ).withValues(alpha: 0.85),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.25,
                                            ),
                                            width: 1,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.5,
                                              ),
                                              blurRadius: 8,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (videoLoading)
                                              LoadingAnimationWidget.staggeredDotsWave(
                                                color: Colors.white,
                                                size: 14,
                                              )
                                            else
                                              const Icon(
                                                Icons.play_arrow_rounded,
                                                color: Colors.white,
                                                size: 18,
                                              ),
                                            const SizedBox(width: 4),
                                            const Text(
                                              'Trailer',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.2,
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
                      ),
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
                            left: 64,
                            right: 98,
                            bottom: 10,
                          ),
                          title: Opacity(
                            opacity: (isCollapsed &&
                                    _trailerProgress.value < 0.1)
                                ? 1.0
                                : 0.0,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: (screenWidth - 170)
                                    .clamp(120.0, 500.0),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(5),
                                    child: CachedNetworkImage(
                                      key: ValueKey(
                                        'preview_mini_poster_${poster}_$_imageRetryEpoch',
                                      ),
                                      imageUrl: poster,
                                      width: 22,
                                      height: 32,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        width: 22,
                                        height: 32,
                                        color: const Color(0xFF1B1D2C),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      movi['title'] ?? widget.title ?? 'Movie',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          background: Stack(
                            fit: StackFit.expand,
                            children: [
                              // 1. Single Movie Backdrop Image (consistent, no image swap)
                              Positioned.fill(
                                child: CachedNetworkImage(
                                  key: ValueKey(
                                    'preview_backdrop_${backdrop}_$_imageRetryEpoch',
                                  ),
                                  imageUrl: backdrop,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) =>
                                      Container(color: const Color(0xFF14141E)),
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        color: const Color(0xFF14141E),
                                        child: const Icon(
                                          Icons.movie_creation_outlined,
                                          size: 64,
                                          color: Colors.white24,
                                        ),
                                      ),
                                ),
                              ),

                              // 2. Multi-stop gradient blend
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      stops: const [0.0, 0.35, 0.72, 1.0],
                                      colors: [
                                        Colors.black.withValues(alpha: 0.65),
                                        Colors.black.withValues(alpha: 0.2),
                                        const Color(
                                          0xFF0D0D14,
                                        ).withValues(alpha: 0.85),
                                        const Color(0xFF0D0D14),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                              // 3. Central Play Button on Sliver (fades out when inline video is playing or collapsed)
                              Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 74),
                                  child: Opacity(
                                    opacity: ((1.0 - _trailerProgress.value) *
                                            (isCollapsed ? 0.0 : 1.0))
                                        .clamp(0.0, 1.0),
                                    child: IgnorePointer(
                                      ignoring: _trailerProgress.value > 0.05 ||
                                          isCollapsed,
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            30,
                                          ),
                                          onTap: _handleTrailerTap,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 9,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.65,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(26),
                                              border: Border.all(
                                                color: Colors.white.withValues(
                                                  alpha: 0.28,
                                                ),
                                                width: 1.2,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.6),
                                                  blurRadius: 14,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ],
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (videoLoading)
                                                  LoadingAnimationWidget.staggeredDotsWave(
                                                    color: Colors.white,
                                                    size: 18,
                                                  )
                                                else
                                                  const Icon(
                                                    Icons.play_arrow_rounded,
                                                    color: Colors.white,
                                                    size: 24,
                                                  ),
                                                const SizedBox(width: 6),
                                                const Text(
                                                  'Watch Trailer',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w700,
                                                    letterSpacing: 0.2,
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
                              ),

                              // 4. Movie Title, Poster & Top Details in front of the sliver (HIDES AT PLAY TIME!)
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 14,
                                child: Opacity(
                                  opacity: ((1.0 - _trailerProgress.value) *
                                          (isCollapsed ? 0.0 : 1.0))
                                      .clamp(0.0, 1.0),
                                  child: IgnorePointer(
                                    ignoring: _trailerProgress.value > 0.05 ||
                                        isCollapsed,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        // Movie Poster Card
                                        SizedBox(
                                          width: 96,
                                          height: 140,
                                          child: Hero(
                                            tag:
                                                widget.heroTag ??
                                                'movie_hero_${widget.movieId}',
                                            createRectTween: (begin, end) =>
                                                MaterialRectCenterArcTween(
                                                  begin: begin,
                                                  end: end,
                                                ),
                                            flightShuttleBuilder:
                                                _buildPosterFlightShuttle,
                                            child: Material(
                                              type: MaterialType.transparency,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  border: Border.all(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.18,
                                                        ),
                                                    width: 1.2,
                                                  ),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                            alpha: 0.7,
                                                          ),
                                                      blurRadius: 18,
                                                      offset: const Offset(
                                                        0,
                                                        6,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(13),
                                                  child: CachedNetworkImage(
                                                    key: ValueKey(
                                                      'preview_poster_${poster}_$_imageRetryEpoch',
                                                    ),
                                                    imageUrl: poster,
                                                    fit: BoxFit.cover,
                                                    placeholder:
                                                        (context, url) =>
                                                            Container(
                                                              color:
                                                                  const Color(
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
                                                            color:
                                                                Colors.white38,
                                                          ),
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
                                                    widget.titleHeroTag ??
                                                    'movie_title_${widget.movieId}',
                                                flightShuttleBuilder:
                                                    _buildTitleFlightShuttle,
                                                child: Material(
                                                  type:
                                                      MaterialType.transparency,
                                                  child: Text(
                                                    movi['title'] ??
                                                        movi['name'] ??
                                                        widget.title ??
                                                        'Movie',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 20,
                                                      fontWeight:
                                                          FontWeight.w800,
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
                                                    overflow:
                                                        TextOverflow.ellipsis,
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
                                                    ((movi['tagline']
                                                                ?.toString())
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
                                                            fontStyle: FontStyle
                                                                .italic,
                                                            shadows: const [
                                                              Shadow(
                                                                color: Colors
                                                                    .black87,
                                                                blurRadius: 4,
                                                                offset: Offset(
                                                                  0,
                                                                  1,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
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
                                                    if (year.isNotEmpty)
                                                      _buildMetaCapsule(
                                                        year,
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
                                                        icon: Icons
                                                            .schedule_rounded,
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
                              ),

                              // 5. Inline YouTube Player with STATUS BAR SAFE AREA! (Taking fixed playerExpandedHeight)
                              if (_sliverYtController != null &&
                                  (_isPlayingInlineTrailer ||
                                      _trailerProgress.value > 0.001))
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  height: playerExpandedHeight,
                                  child: Opacity(
                                    opacity:
                                        _trailerProgress.value.clamp(0.0, 1.0),
                                    child: IgnorePointer(
                                      ignoring: _trailerProgress.value < 0.8,
                                      child: Container(
                                        color: Colors.black,
                                        child: SafeArea(
                                          bottom: false,
                                          child: Center(
                                            child: AspectRatio(
                                              aspectRatio: 16 / 9,
                                              child: YoutubePlayer(
                                                controller:
                                                    _sliverYtController!,
                                                showVideoProgressIndicator:
                                                    false,
                                                topActions: [
                                                  const Spacer(),
                                                  // Single Close Button safely below status bar
                                                  Material(
                                                    color: Colors.black54,
                                                    shape: const CircleBorder(),
                                                    child: IconButton(
                                                      icon: const Icon(
                                                        Icons.close_rounded,
                                                        color: Colors.white,
                                                        size: 20,
                                                      ),
                                                      tooltip: 'Close Trailer',
                                                      onPressed:
                                                          _stopInlineTrailer,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                ],
                                                bottomActions: [
                                                  const SizedBox(width: 14),
                                                  ProgressBar(
                                                    isExpanded: true,
                                                    colors:
                                                        const ProgressBarColors(
                                                          playedColor:
                                                              Colors.redAccent,
                                                          handleColor:
                                                              Colors.white,
                                                          bufferedColor:
                                                              Colors.white24,
                                                          backgroundColor:
                                                              Colors.white12,
                                                        ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  IconButton(
                                                    icon: const Icon(
                                                      Icons.fullscreen_rounded,
                                                      color: Colors.white,
                                                      size: 22,
                                                    ),
                                                    tooltip: 'Full Screen',
                                                    onPressed:
                                                        _openFullScreenFromSliver,
                                                  ),
                                                  const SizedBox(width: 6),
                                                ],
                                                onEnded: (meta) {
                                                  _stopInlineTrailer();
                                                },
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // 1b. Slow / Offline Status Banner
                  if (_isSlowConnection && _detailsLoading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: NetworkStatusBanner(
                          isSlow: true,
                          message:
                              'Slow connection detected — loading full movie details...',
                        ),
                      ),
                    )
                  else if (_detailsFailureType != NetworkFailureType.none)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: NetworkStatusBanner(
                          isOffline: _detailsFailureType ==
                              NetworkFailureType.noInternet,
                          isSlow: _detailsFailureType ==
                              NetworkFailureType.slowOrTimeout,
                          message: _detailsFailureType ==
                                  NetworkFailureType.noInternet
                              ? 'No internet — some movie details unavailable'
                              : 'Slow connection — failed to load full details',
                          onRetry: () {
                            getMovieDetails();
                            getVideo();
                          },
                        ),
                      ),
                    ),

                  // 2. Action Dock, Multi-Trailer & Genre Pills
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                              if (_isUpcomingMovie()) ...[
                                Expanded(
                                  child: _buildActionTile(
                                    icon: _isReminded
                                        ? Icons.notifications_active_rounded
                                        : Icons.notification_add_outlined,
                                    iconColor: _isReminded
                                        ? const Color(0xFFFF9F1C)
                                        : Colors.white70,
                                    label: _isReminded ? 'Reminded' : 'Remind Me',
                                    onTap: _toggleReminder,
                                  ),
                                ),
                              ] else ...[
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
                              ],
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

                          // Multi-Video / Teaser Selector (if multiple videos available)
                          if (videoList.length > 1) ...[
                            const SizedBox(height: 14),
                            SizedBox(
                              height: 34,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: videoList.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final v = videoList[index];
                                  final isSelected =
                                      (videos['key'] == v['key']);
                                  final label =
                                      (v['name'] ??
                                              v['type'] ??
                                              'Video ${index + 1}')
                                          .toString();
                                  return GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        videos = v;
                                      });
                                      _playInlineTrailer(v['key'] ?? '');
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.white.withValues(
                                                alpha: 0.16,
                                              )
                                            : const Color(0xFF1B1D2C),
                                        borderRadius: BorderRadius.circular(17),
                                        border: Border.all(
                                          color: isSelected
                                              ? Colors.white.withValues(
                                                  alpha: 0.4,
                                                )
                                              : Colors.white.withValues(
                                                  alpha: 0.12,
                                                ),
                                          width: 1,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isSelected
                                                ? Icons
                                                      .play_circle_filled_rounded
                                                : Icons.play_arrow_rounded,
                                            size: 16,
                                            color: isSelected
                                                ? Colors.white
                                                : Colors.white70,
                                          ),
                                          const SizedBox(width: 5),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 160,
                                            ),
                                            child: Text(
                                              label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isSelected
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontSize: 12,
                                                fontWeight: isSelected
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                              ),
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

                          const SizedBox(height: 16),

                          // Genre Pills (Clean shimmer loading until official movie genres load)
                          AnimatedCrossFade(
                            duration: const Duration(milliseconds: 300),
                            crossFadeState: genre.isNotEmpty
                                ? CrossFadeState.showFirst
                                : CrossFadeState.showSecond,
                            firstChild: genre.isNotEmpty
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 13,
                                                    vertical: 5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF161622),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.08),
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
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    genre[index].toString(),
                                                    style: const TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600,
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
                            secondChild: _detailsLoading
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        height: 32,
                                        child: Shimmer.fromColors(
                                          baseColor: const Color(0xFF222233),
                                          highlightColor:
                                              const Color(0xFF3D3D56),
                                          period: const Duration(
                                              milliseconds: 1000),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 76,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF222233),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Container(
                                                width: 92,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF222233),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Container(
                                                width: 68,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF222233),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Container(
                                                width: 80,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF222233),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                    ],
                                  )
                                : const SizedBox.shrink(),
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
                      child:
                          ((movi['overview']?.toString())?.isNotEmpty ?? false)
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
                                      color: Colors.white.withValues(
                                        alpha: 0.78,
                                      ),
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

                  // 7. Movie Details (Clean Unified Bento Card)
                  SliverToBoxAdapter(
                    child: Builder(
                      builder: (context) {
                        final releaseDates = _extractReleaseDates();
                        final theatricalDate = releaseDates['theatrical'];
                        final digitalDate = releaseDates['digital'];
                        final ottPlatforms = _extractOttPlatforms();
                        final String origLang = _extractOriginalLanguage();
                        final String runtimeStr = _formatRuntime(movi['runtime']);
                        final String statusStr =
                            (movi['status'] ?? '').toString().trim();

                        final budgetText = _formatCurrency(movi['budget']);
                        final bool hasBudget = budgetText != 'N/A';
                        final revenueText = _formatCurrency(movi['revenue']);
                        final bool hasRevenue = revenueText != 'N/A';

                        return Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSectionHeading('Movie Details'),
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF131622),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.07),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Top Row: Theatrical vs OTT Release
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildReleaseMiniTile(
                                            icon: Icons.theaters_rounded,
                                            label: 'Theatre',
                                            value: theatricalDate != null
                                                ? _formatDate(theatricalDate)
                                                : 'TBA',
                                            accent: const Color(0xFF64D2FF),
                                            isHighlighted:
                                                theatricalDate != null,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _buildReleaseMiniTile(
                                            icon: Icons.live_tv_rounded,
                                            label: 'OTT',
                                            value: digitalDate != null
                                                ? _formatDate(digitalDate)
                                                : 'TBA',
                                            accent: const Color(0xFF00E5A0),
                                            isHighlighted: digitalDate != null,
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 12),
                                    Divider(
                                      color: Colors.white.withValues(alpha: 0.06),
                                      height: 1,
                                    ),
                                    const SizedBox(height: 12),

                                    // Compact Quick-Facts Wrap
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _buildDetailFactChip(
                                          icon: Icons.translate_rounded,
                                          label: 'Language',
                                          value: origLang,
                                          color: const Color(0xFF00E5A0),
                                        ),
                                        if (runtimeStr.isNotEmpty)
                                          _buildDetailFactChip(
                                            icon: Icons.schedule_rounded,
                                            label: 'Runtime',
                                            value: runtimeStr,
                                            color: const Color(0xFF64D2FF),
                                          ),
                                        if (statusStr.isNotEmpty)
                                          _buildDetailFactChip(
                                            icon: Icons.verified_outlined,
                                            label: 'Status',
                                            value: statusStr,
                                            color: const Color(0xFFB388FF),
                                          ),
                                        if (hasBudget)
                                          _buildDetailFactChip(
                                            icon: Icons
                                                .account_balance_wallet_rounded,
                                            label: 'Budget',
                                            value: budgetText,
                                            color: const Color(0xFFFFD166),
                                          ),
                                        if (hasRevenue)
                                          _buildDetailFactChip(
                                            icon: Icons.trending_up_rounded,
                                            label: 'Box Office',
                                            value: revenueText,
                                            color: const Color(0xFFFF9F1C),
                                          ),
                                      ],
                                    ),

                                    // Streaming Platforms integrated cleanly
                                    if (ottPlatforms.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Divider(
                                        color:
                                            Colors.white.withValues(alpha: 0.06),
                                        height: 1,
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.play_circle_outline_rounded,
                                            color: Color(0xFF00E5A0),
                                            size: 15,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Streaming On',
                                            style: TextStyle(
                                              color:
                                                  Colors.white.withValues(alpha: 0.75),
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: ottPlatforms.map((p) {
                                          final name = p['name'] ?? '';
                                          final logo = p['logo'] ?? '';
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 9,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.04,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                color: Colors.white.withValues(
                                                  alpha: 0.08,
                                                ),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (logo.isNotEmpty) ...[
                                                  ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      5,
                                                    ),
                                                    child: CachedNetworkImage(
                                                      imageUrl:
                                                          '${AppConstants.baseImageUrl}$logo',
                                                      width: 18,
                                                      height: 18,
                                                      fit: BoxFit.cover,
                                                      errorWidget: (_, _, _) =>
                                                          const Icon(
                                                        Icons
                                                            .play_circle_fill_rounded,
                                                        size: 16,
                                                        color:
                                                            Color(0xFF00E5A0),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                ],
                                                Flexible(
                                                  child: Text(
                                                    name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 11.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // 8. Top Cast Horizontal Section (First 5 actors with View All button)
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
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        _buildSectionHeading(
                                          'Top Cast',
                                          count: actors.length,
                                        ),
                                        if (actors.length > 5)
                                          Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              onTap: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) =>
                                                        AllCastPage(
                                                          movieTitle:
                                                              movi['title'] ??
                                                              widget.title ??
                                                              'Movie',
                                                          actors: actors,
                                                        ),
                                                  ),
                                                );
                                              },
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 4,
                                                    ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Text(
                                                      'View All',
                                                      style: TextStyle(
                                                        color: Color(
                                                          0xFF00E5A0,
                                                        ),
                                                        fontSize: 12.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 3),
                                                    const Icon(
                                                      Icons
                                                          .arrow_forward_ios_rounded,
                                                      color: Color(0xFF00E5A0),
                                                      size: 11,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
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
                                      itemCount: actors.length > 5
                                          ? 5
                                          : actors.length,
                                      separatorBuilder: (context, index) =>
                                          const SizedBox(width: 12),
                                      itemBuilder: (context, index) {
                                        final actor = actors[index];
                                        final profilePath =
                                            actor['profile_path'];
                                        final actorName =
                                            actor['name'] ?? 'Actor';
                                        final character =
                                            actor['character'] ?? '';

                                        return GestureDetector(
                                          onTap: () {
                                            if (actor['id'] != null) {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) =>
                                                      ActorPreviewPage(
                                                        personId: actor['id'],
                                                        initialName: actorName,
                                                        initialProfilePath:
                                                            profilePath,
                                                        initialCharacter:
                                                            character,
                                                        heroTag:
                                                            'cast_actor_${widget.movieId}_${actor['id']}_$index',
                                                      ),
                                                ),
                                              );
                                            }
                                          },
                                          child: SizedBox(
                                            width: 95,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Hero(
                                                  tag:
                                                      'cast_actor_${widget.movieId}_${actor['id']}_$index',
                                                  child: Container(
                                                    width: 95,
                                                    height: 115,
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            14,
                                                          ),
                                                      border: Border.all(
                                                        color: Colors.white
                                                            .withValues(
                                                              alpha: 0.08,
                                                            ),
                                                      ),
                                                      color: const Color(
                                                        0xFF161622,
                                                      ),
                                                    ),
                                                    child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          13,
                                                        ),
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
                                                                  color: const Color(
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
                                                                    Icons
                                                                        .person,
                                                                    color: Colors
                                                                        .white24,
                                                                    size: 36,
                                                                  ),
                                                                ),
                                                          )
                                                        : const Center(
                                                            child: Icon(
                                                              Icons.person,
                                                              color: Colors
                                                                  .white24,
                                                              size: 36,
                                                            ),
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
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                if (character.isNotEmpty)
                                                  Text(
                                                    character,
                                                    style: TextStyle(
                                                      color:
                                                          Colors.grey.shade400,
                                                      fontSize: 10.5,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                              ],
                                            ),
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

                  // 8b. Director & Crew Section
                  SliverToBoxAdapter(child: _buildCrewSection()),

                  // 8c. HD Photos & Backdrops Gallery
                  SliverToBoxAdapter(child: _buildGallerySection()),

                  // 8d. Linked Telegram Bot Stream Videos (when tagged with tmdb:<id>)
                  SliverToBoxAdapter(child: _buildBotStreamSection()),

                  // 8e. Movie Songs & Soundtracks (YouTube Data API v3)
                  SliverToBoxAdapter(child: _buildSongsSection()),

                  // 8e. Franchise & Saga Collection
                  SliverToBoxAdapter(
                    child: _buildCollectionSection(),
                  ),

                  // 9. Reviews Section
                  SliverToBoxAdapter(
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
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
                                padding: EdgeInsets.zero,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: reviews.length > 4
                                    ? 4
                                    : reviews.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final review = reviews[index];
                                  final author =
                                      review['author'] ?? 'Anonymous';
                                  final content = (review['content'] ?? '')
                                      .toString()
                                      .trim();
                                  final rating =
                                      (review['author_details']?['rating'] ??
                                          0) /
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
                                      mainAxisSize: MainAxisSize.min,
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
                                                      fontWeight:
                                                          FontWeight.bold,
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
                                                        color: Colors
                                                            .grey
                                                            .shade500,
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
                                                borderColor:
                                                    Colors.grey.shade700,
                                                allowHalfRating: true,
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        ReadMoreText(
                                          content,
                                          trimLines: 4,
                                          trimMode: TrimMode.Line,
                                          trimCollapsedText: ' Read more',
                                          trimExpandedText: ' Show less',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.72,
                                            ),
                                            fontSize: 12.5,
                                            height: 1.4,
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
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                ),
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
              )),
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

  Widget _buildCrewSection() {
    if (_crewMembers.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildSectionHeading(
              'Director & Crew',
              count: _crewMembers.length,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 76,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              scrollDirection: Axis.horizontal,
              itemCount: _crewMembers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final member = _crewMembers[index];
                final name = (member['name'] ?? 'Crew').toString();
                final roles = (member['roles'] as List<String>).join(' • ');
                final profilePath = member['profile_path']?.toString();
                final isDirector =
                    (member['roles'] as List<String>).contains('Director');

                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ActorPreviewPage(
                          personId: member['id'],
                          initialName: name,
                          initialProfilePath: profilePath,
                          initialCharacter: roles,
                          heroTag:
                              'crew_actor_${widget.movieId}_${member['id']}_$index',
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF14141E),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isDirector
                            ? const Color(0xFF00E5A0).withValues(alpha: 0.35)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Hero(
                          tag:
                              'crew_actor_${widget.movieId}_${member['id']}_$index',
                          child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 44,
                            height: 54,
                            child: profilePath != null && profilePath.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl:
                                        '${AppConstants.baseImageUrl}$profilePath',
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) => Container(
                                      color: const Color(0xFF1C1F2E),
                                      child: const Icon(
                                        Icons.person,
                                        color: Colors.white24,
                                        size: 20,
                                      ),
                                    ),
                                  )
                                : Container(
                                    color: const Color(0xFF1C1F2E),
                                    child: const Icon(
                                      Icons.person,
                                      color: Colors.white24,
                                      size: 20,
                                    ),
                                  ),
                          ),
                        ),
                        ),
                        const SizedBox(width: 10),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 145),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                roles,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDirector
                                      ? const Color(0xFF00E5A0)
                                      : Colors.white54,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
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
      ),
    );
  }

  Widget _buildGallerySection() {
    if (_galleryImages.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildSectionHeading(
              'HD Photos & Backdrops',
              count: _galleryImages.length,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 122,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              scrollDirection: Axis.horizontal,
              itemCount: _galleryImages.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final path = _galleryImages[index];
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImageGalleryPage(
                          imagePaths: _galleryImages,
                          initialIndex: index,
                          title: (movi['title'] ?? widget.title ?? 'Gallery')
                              .toString(),
                          heroTagPrefix: 'movie_gallery_${widget.movieId}',
                        ),
                      ),
                    );
                  },
                  child: Hero(
                    tag: 'movie_gallery_${widget.movieId}_$index',
                    child: Container(
                      width: 196,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                        color: const Color(0xFF14141E),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: 'https://image.tmdb.org/t/p/w780$path',
                              fit: BoxFit.cover,
                              placeholder: (_, _) => Container(
                                color: const Color(0xFF161824),
                              ),
                              errorWidget: (_, _, _) => const Center(
                                child: Icon(
                                  Icons.broken_image_rounded,
                                  color: Colors.white24,
                                ),
                              ),
                            ),
                            Positioned(
                              right: 8,
                              bottom: 8,
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.fullscreen_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
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
        ],
      ),
    );
  }

  Widget _buildBotStreamSection() {
    if (_matchedBotVideos.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildSectionHeading(
              'Cloud Video Stream',
              count: _matchedBotVideos.length,
            ),
          ),
          const SizedBox(height: 12),
          for (final item in _matchedBotVideos)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  HapticFeedback.lightImpact();
                  if (_isPlayingInlineTrailer) {
                    _sliverYtController?.pause();
                  }
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
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141825),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF00E5A0).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5A0).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Color(0xFF00E5A0),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${item.formatBadge}${item.fileSize > 0 ? ' • ${TelegramStreamService.formatBytes(item.fileSize)}' : ''}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Color(0xFF00E5A0),
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

  Widget _buildSongsSection() {
    final movieTitle =
        (movi['title'] ?? movi['name'] ?? widget.title ?? 'Movie').toString();

    if (!_songsLoading &&
        _songsHasKey &&
        _songsError == null &&
        _movieSongs.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildSectionHeading(
                  'Movie Songs',
                  count: _movieSongs.isNotEmpty ? _movieSongs.length : null,
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _searchYouTube('$movieTitle songs'),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.open_in_new_rounded,
                          color: Color(0xFF00E5A0),
                          size: 13,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'YouTube',
                          style: TextStyle(
                            color: Color(0xFF00E5A0),
                            fontSize: 12,
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
          const SizedBox(height: 12),
          if (_songsLoading)
            SizedBox(
              height: 152,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                scrollDirection: Axis.horizontal,
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, _) => Shimmer.fromColors(
                  baseColor: const Color(0xFF141724),
                  highlightColor: const Color(0xFF23283D),
                  child: Container(
                    width: 210,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            )
          else if (!_songsHasKey)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _searchYouTube('$movieTitle movie songs'),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF14141E),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.music_note_rounded,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Listen to "$movieTitle" Songs',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Add YouTube Data API v3 key in keys.dart for in-app songs, or tap to open YouTube.',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.redAccent,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_songsError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: NetworkStatusBanner(
                isOffline: _songsError!.toLowerCase().contains('no internet'),
                isSlow: _songsError!.toLowerCase().contains('slow'),
                message: _songsError!,
                onRetry: _fetchMovieSongs,
              ),
            )
          else
            SizedBox(
              height: 170,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                scrollDirection: Axis.horizontal,
                itemCount: _movieSongs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final song = _movieSongs[index];
                  final songTitle = song['title'] ?? 'Song';
                  final channel = song['channel'] ?? '';
                  final thumb = song['thumb'] ?? '';

                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _openSongPlayerSheet(index, movieTitle);
                    },
                    child: SizedBox(
                      width: 210,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 118,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                              ),
                              color: const Color(0xFF14141E),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedNetworkImage(
                                    imageUrl: thumb,
                                    fit: BoxFit.cover,
                                    placeholder: (_, _) => Container(
                                      color: const Color(0xFF161824),
                                    ),
                                    errorWidget: (_, _, _) => const Center(
                                      child: Icon(
                                        Icons.music_note_rounded,
                                        color: Colors.white24,
                                        size: 30,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.7,
                                          ),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.35,
                                            ),
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            songTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (channel.isNotEmpty)
                            Text(
                              channel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey.shade400,
                                fontSize: 11,
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
      ),
    );
  }

  void _openSongPlayerSheet(int initialIndex, String movieTitle) {
    if (_movieSongs.isEmpty) return;
    if (_isPlayingInlineTrailer) {
      _sliverYtController?.pause();
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MovieSongPlayerSheet(
        movieTitle: movieTitle,
        songs: _movieSongs,
        initialIndex: initialIndex,
      ),
    );
  }

  Widget _buildReleaseMiniTile({
    required IconData icon,
    required String label,
    required String value,
    required Color accent,
    required bool isHighlighted,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isHighlighted
            ? accent.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isHighlighted
              ? accent.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: isHighlighted ? accent : Colors.white54,
                size: 14,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isHighlighted ? accent : Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isHighlighted ? Colors.white : Colors.white54,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailFactChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
                        Container(
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
                                    placeholder: (context, url) => Container(
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
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              widget.title != null
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
                                        borderRadius: BorderRadius.circular(6),
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

  Future<void> _exitFullscreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
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
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                YoutubePlayer(
                  controller: _controller,
                  showVideoProgressIndicator: true,
                  progressIndicatorColor: Colors.redAccent,
                  progressColors: const ProgressBarColors(
                    playedColor: Colors.redAccent,
                    handleColor: Colors.redAccent,
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
                        playedColor: Colors.redAccent,
                        handleColor: Colors.redAccent,
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    RemainingDuration(),
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
    );
  }
}

/// Full Cast & Crew Grid Page
class AllCastPage extends StatelessWidget {
  final String movieTitle;
  final List<dynamic> actors;

  const AllCastPage({
    super.key,
    required this.movieTitle,
    required this.actors,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D14),
        elevation: 0,
        leading: Center(
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 16,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cast & Crew',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              movieTitle,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: actors.isEmpty
          ? const Center(
              child: Text(
                'No cast information available',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: 0.58,
              ),
              itemCount: actors.length,
              itemBuilder: (context, index) {
                final actor = actors[index];
                final profilePath = actor['profile_path'];
                final actorName = actor['name'] ?? 'Actor';
                final character = actor['character'] ?? '';

                return GestureDetector(
                  onTap: () {
                    if (actor['id'] != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ActorPreviewPage(
                            personId: actor['id'],
                            initialName: actorName,
                            initialProfilePath: profilePath,
                            initialCharacter: character,
                            heroTag:
                                'all_cast_actor_${actor['id']}_$index',
                          ),
                        ),
                      );
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Hero(
                          tag:
                              'all_cast_actor_${actor['id']}_$index',
                          child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                            color: const Color(0xFF161622),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(13),
                            child: profilePath != null
                                ? CachedNetworkImage(
                                    imageUrl:
                                        '${AppConstants.baseImageUrl}$profilePath',
                                    width: double.infinity,
                                    height: double.infinity,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => Container(
                                      color: const Color(0xFF161622),
                                    ),
                                    errorWidget: (context, url, error) =>
                                        const Center(
                                          child: Icon(
                                            Icons.person,
                                            color: Colors.white24,
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
    );
  }
}

class _MovieSongPlayerSheet extends StatefulWidget {
  final String movieTitle;
  final List<Map<String, String>> songs;
  final int initialIndex;

  const _MovieSongPlayerSheet({
    required this.movieTitle,
    required this.songs,
    required this.initialIndex,
  });

  @override
  State<_MovieSongPlayerSheet> createState() => _MovieSongPlayerSheetState();
}

class _MovieSongPlayerSheetState extends State<_MovieSongPlayerSheet> {
  late YoutubePlayerController _ytController;
  late int _currentIndex;
  bool _isFullScreenSheet = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.songs.length - 1);
    final videoId = widget.songs[_currentIndex]['videoId'] ?? '';
    _ytController = YoutubePlayerController(
      initialVideoId: videoId,
      flags: const YoutubePlayerFlags(
        autoPlay: true,
        mute: false,
        enableCaption: false,
        useHybridComposition: true,
      ),
    );
  }

  @override
  void dispose() {
    _ytController.dispose();
    super.dispose();
  }

  void _playIndex(int index) {
    if (index < 0 || index >= widget.songs.length) return;
    HapticFeedback.selectionClick();
    final videoId = widget.songs[index]['videoId'] ?? '';
    if (videoId.isEmpty) return;
    setState(() => _currentIndex = index);
    _ytController.load(videoId);
  }

  Future<void> _openFullscreen() async {
    final currentPos = _ytController.value.position;
    final isPlaying = _ytController.value.isPlaying;
    _ytController.pause();

    final song = widget.songs[_currentIndex];
    final videoId = song['videoId'] ?? '';
    final result = await Navigator.push<Duration>(
      context,
      MaterialPageRoute(
        builder: (_) => LandscapeTrailerPlayer(
          videoId: videoId,
          startAt: currentPos,
          heroTag: 'song_player_$videoId',
          title: song['title'] ?? widget.movieTitle,
        ),
      ),
    );

    if (result != null && mounted) {
      _ytController.seekTo(result);
      if (isPlaying) _ytController.play();
    }
  }

  Future<void> _openInYouTube(String videoId) async {
    final uri = Uri.parse('https://www.youtube.com/watch?v=$videoId');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5A0);
    final song = widget.songs[_currentIndex];
    final songTitle = song['title'] ?? 'Song';
    final channel = song['channel'] ?? '';
    final videoId = song['videoId'] ?? '';
    final hasPrev = _currentIndex > 0;
    final hasNext = _currentIndex < widget.songs.length - 1;

    final mediaSize = MediaQuery.of(context).size;
    final isLandscape = mediaSize.width > mediaSize.height;
    final sheetHeight = isLandscape
        ? mediaSize.height * (_isFullScreenSheet ? 0.96 : 0.85)
        : mediaSize.height * (_isFullScreenSheet ? 0.95 : 0.75);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: sheetHeight,
      decoration: const BoxDecoration(
        color: Color(0xFF12141F),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0xFF252A3B), width: 1)),
      ),
      child: SafeArea(
        top: _isFullScreenSheet,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompactHeight = constraints.maxHeight < 460;
            final maxPlayerHeight = (constraints.maxHeight - 190).clamp(
              110.0,
              420.0,
            );
            final headerWidget = Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.music_note_rounded,
                      color: accent,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.movieTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Song ${_currentIndex + 1} of ${widget.songs.length}',
                          style: const TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isFullScreenSheet
                          ? Icons.close_fullscreen_rounded
                          : Icons.open_in_full_rounded,
                      color: Colors.white70,
                      size: 19,
                    ),
                    tooltip: _isFullScreenSheet ? '3/4 Size' : 'Full Screen',
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      setState(
                        () => _isFullScreenSheet = !_isFullScreenSheet,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 22,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            );
            final playerWidget = Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxPlayerHeight),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: YoutubePlayer(
                        controller: _ytController,
                        showVideoProgressIndicator: true,
                        progressIndicatorColor: accent,
                        progressColors: const ProgressBarColors(
                          playedColor: accent,
                          handleColor: accent,
                          bufferedColor: Colors.white24,
                          backgroundColor: Colors.white10,
                        ),
                        bottomActions: [
                          const SizedBox(width: 8),
                          CurrentPosition(),
                          const SizedBox(width: 8),
                          ProgressBar(
                            isExpanded: true,
                            colors: const ProgressBarColors(
                              playedColor: accent,
                              handleColor: accent,
                              bufferedColor: Colors.white24,
                              backgroundColor: Colors.white10,
                            ),
                          ),
                          const SizedBox(width: 8),
                          RemainingDuration(),
                          const PlaybackSpeedButton(),
                          IconButton(
                            icon: const Icon(
                              Icons.fullscreen_rounded,
                              color: Colors.white,
                            ),
                            tooltip: 'Fullscreen',
                            onPressed: _openFullscreen,
                          ),
                        ],
                        onEnded: (_) {
                          if (_currentIndex < widget.songs.length - 1) {
                            _playIndex(_currentIndex + 1);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            final controlsRow = Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          songTitle,
                          maxLines: isCompactHeight ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (channel.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            channel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed:
                        hasPrev ? () => _playIndex(_currentIndex - 1) : null,
                    icon: Icon(
                      Icons.skip_previous_rounded,
                      color: hasPrev ? Colors.white : Colors.white24,
                    ),
                    tooltip: 'Previous',
                  ),
                  IconButton(
                    onPressed:
                        hasNext ? () => _playIndex(_currentIndex + 1) : null,
                    icon: Icon(
                      Icons.skip_next_rounded,
                      color: hasNext ? Colors.white : Colors.white24,
                    ),
                    tooltip: 'Next',
                  ),
                  IconButton(
                    onPressed: _openFullscreen,
                    icon: const Icon(
                      Icons.fullscreen_rounded,
                      color: accent,
                    ),
                    tooltip: 'Fullscreen',
                  ),
                  IconButton(
                    onPressed: () => _openInYouTube(videoId),
                    icon: const Icon(
                      Icons.open_in_new_rounded,
                      color: Colors.white70,
                      size: 19,
                    ),
                    tooltip: 'Open in YouTube',
                  ),
                ],
              ),
            );
            Widget buildQueueList({required bool shrinkWrap}) {
              return ListView.builder(
                shrinkWrap: shrinkWrap,
                physics: shrinkWrap
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                itemCount: widget.songs.length,
                itemBuilder: (_, idx) {
                  final item = widget.songs[idx];
                  final isCurrent = idx == _currentIndex;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _playIndex(idx),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? accent.withValues(alpha: 0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: isCurrent
                            ? Border.all(
                                color: accent.withValues(alpha: 0.35),
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 56,
                              height: 34,
                              child: CachedNetworkImage(
                                imageUrl: item['thumb'] ?? '',
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => Container(
                                  color: const Color(0xFF1B1F2E),
                                  child: const Icon(
                                    Icons.music_note_rounded,
                                    size: 16,
                                    color: Colors.white24,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['title'] ?? 'Song',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent ? accent : Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: isCurrent
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                if ((item['channel'] ?? '').isNotEmpty)
                                  Text(
                                    item['channel']!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 10.5,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            const Icon(
                              Icons.graphic_eq_rounded,
                              color: accent,
                              size: 18,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            }

            final dragHandle = Column(
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            );

            if (isCompactHeight) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    dragHandle,
                    headerWidget,
                    playerWidget,
                    controlsRow,
                    if (widget.songs.length > 1) ...[
                      const Divider(color: Color(0xFF1F2434), height: 1),
                      buildQueueList(shrinkWrap: true),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                dragHandle,
                headerWidget,
                playerWidget,
                controlsRow,
                if (widget.songs.length > 1) ...[
                  const Divider(color: Color(0xFF1F2434), height: 1),
                  Expanded(child: buildQueueList(shrinkWrap: false)),
                ],
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}
