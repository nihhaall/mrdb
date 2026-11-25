import 'dart:async';
import 'dart:math';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';

class RandomMoviePickerPage extends StatefulWidget {
  final Map<String, dynamic> pickedMovie;
  final String subtitle;
  final List<dynamic> candidateMovies;

  const RandomMoviePickerPage({
    super.key,
    required this.pickedMovie,
    required this.subtitle,
    required this.candidateMovies,
  });

  @override
  State<RandomMoviePickerPage> createState() => _RandomMoviePickerPageState();
}

class _RandomMoviePickerPageState extends State<RandomMoviePickerPage>
    with TickerProviderStateMixin {
  late final AnimationController _progressController;
  late final AnimationController _pulseController;
  late final AnimationController _revealController;

  Timer? _stepTimer;
  Timer? _countdownTimer;

  late Map<String, dynamic> _displayedMovie;
  bool _isFinalSelected = false;
  int _secondsLeft = 5;
  String _statusText = 'Shuffling movies...';

  // Pool of candidate movies guaranteed to have real, authentic posters
  late final List<Map<String, dynamic>> _shufflePool;

  @override
  void initState() {
    super.initState();

    // 1. Prepare shuffle pool with strict poster validation
    bool isValidMovieWithPoster(dynamic m) {
      if (m is! Map<String, dynamic>) return false;
      final poster = m['poster_path']?.toString().trim();
      return poster != null &&
          poster.isNotEmpty &&
          poster != 'null' &&
          poster != 'undefined';
    }

    final validCandidates = widget.candidateMovies
        .where(isValidMovieWithPoster)
        .cast<Map<String, dynamic>>()
        .toList();

    _shufflePool = validCandidates.isNotEmpty
        ? validCandidates
        : (isValidMovieWithPoster(widget.pickedMovie)
            ? [widget.pickedMovie]
            : [
                {
                  'id': widget.pickedMovie['id'],
                  'title': widget.pickedMovie['title'] ?? 'Movie',
                  'poster_path': widget.pickedMovie['poster_path'],
                  'vote_average': widget.pickedMovie['vote_average'] ?? 7.0,
                }
              ]);

    _displayedMovie = _shufflePool.first;

    // 2. Progress Controller (0 to 1 over 5.0 seconds)
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5000),
    )..forward();

    // 3. Ambient Pulse Controller
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    // 4. Reveal Animation Controller
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // 5. Countdown Display Timer
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_secondsLeft > 1) {
        setState(() => _secondsLeft--);
      } else {
        timer.cancel();
      }
    });

    // 6. Start the Slot-Machine Deceleration Sequence
    _runDeceleratingRoulette();
  }

  /// Gradually widens step intervals to mimic an authentic mechanical slot-machine deceleration
  void _runDeceleratingRoulette() {
    final random = Random();
    int elapsedMs = 0;
    int currentIntervalMs = 70;

    void nextStep() {
      if (!mounted) return;

      if (elapsedMs < 2800) {
        // Phase 1: High speed shuffle (0 - 2.8s)
        currentIntervalMs = 70;
        _displayedMovie = _shufflePool[random.nextInt(_shufflePool.length)];
        HapticFeedback.selectionClick();
        _statusText = 'Rolling through top picks...';
      } else if (elapsedMs < 4000) {
        // Phase 2: Decelerating spin (2.8s - 4.0s)
        currentIntervalMs = (currentIntervalMs * 1.35).clamp(80, 280).toInt();
        _displayedMovie = _shufflePool[random.nextInt(_shufflePool.length)];
        HapticFeedback.lightImpact();
        _statusText = 'Locking onto a favorite...';
      } else if (elapsedMs < 4400) {
        // Phase 3: Final lock-in (4.0s - 4.4s)
        currentIntervalMs = 350;
        _displayedMovie = widget.pickedMovie;
        HapticFeedback.mediumImpact();
        _statusText = 'Almost there...';
      } else {
        // Phase 4: Final Winner Revealed!
        _displayedMovie = widget.pickedMovie;
        _isFinalSelected = true;
        _statusText = "It's a Match!";
        _revealController.forward();
        HapticFeedback.heavyImpact();
        setState(() {});

        Future.delayed(const Duration(milliseconds: 650), () {
          if (!mounted) return;
          _navigateToPreview();
        });
        return;
      }

      setState(() {});
      elapsedMs += currentIntervalMs;
      _stepTimer = Timer(Duration(milliseconds: currentIntervalMs), nextStep);
    }

    nextStep();
  }

  void _navigateToPreview() {
    _stepTimer?.cancel();
    _countdownTimer?.cancel();

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, animation, secondaryAnimation) {
          return MoviePreview(
            movieId: widget.pickedMovie['id'],
            initialMovie: widget.pickedMovie,
            posterPath: widget.pickedMovie['poster_path'],
            title: widget.pickedMovie['title'] ?? widget.pickedMovie['name'],
            backdropPath: widget.pickedMovie['backdrop_path'],
            subtitle: widget.subtitle,
            heroTag: 'roulette_${widget.pickedMovie['id']}',
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
  void dispose() {
    _stepTimer?.cancel();
    _countdownTimer?.cancel();
    _progressController.dispose();
    _pulseController.dispose();
    _revealController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final double wt = size.width;
    final double ht = size.height;

    final posterPath = _displayedMovie['poster_path']?.toString().trim();
    final title = (_displayedMovie['title'] ??
            _displayedMovie['name'] ??
            'Selecting Movie...')
        .toString();
    final rating = (_displayedMovie['vote_average'] ?? 0.0);
    final ratingStr =
        rating is num ? rating.toStringAsFixed(1) : rating.toString();

    final bool hasValidPoster = posterPath != null &&
        posterPath.isNotEmpty &&
        posterPath != 'null' &&
        posterPath != 'undefined';

    return Scaffold(
      backgroundColor: const Color(0xFF090A10),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Ambient Glow Accent
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final double pulseVal = _pulseController.value;
              return Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.1),
                    radius: 0.9 + (pulseVal * 0.15),
                    colors: [
                      _isFinalSelected
                          ? const Color(0xFF00E5A0).withValues(alpha: 0.22)
                          : const Color(0xFFFF9F1C).withValues(alpha: 0.16),
                      Colors.transparent,
                    ],
                  ),
                ),
              );
            },
          ),

          // 2. Main Content
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double cardHeight = (constraints.maxHeight * 0.50).clamp(240.0, 380.0);
                final double cardWidth = cardHeight * 0.67;

                return Column(
                  children: [
                    // Top App Bar with Close Button & Title
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              Navigator.pop(context);
                            },
                            icon: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                color: Colors.white70,
                                size: 19,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Category Tag
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _isFinalSelected
                                  ? const Color(0xFF00E5A0).withValues(alpha: 0.15)
                                  : const Color(0xFFFF9F1C).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _isFinalSelected
                                    ? const Color(0xFF00E5A0).withValues(alpha: 0.4)
                                    : const Color(0xFFFF9F1C).withValues(alpha: 0.4),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isFinalSelected
                                      ? Icons.auto_awesome_rounded
                                      : Icons.movie_filter_rounded,
                                  color: _isFinalSelected
                                      ? const Color(0xFF00E5A0)
                                      : const Color(0xFFFF9F1C),
                                  size: 14,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _isFinalSelected ? 'MATCH FOUND' : 'MOVIE ROULETTE',
                                  style: TextStyle(
                                    color: _isFinalSelected
                                        ? const Color(0xFF00E5A0)
                                        : const Color(0xFFFF9F1C),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 48), // Balance close button
                        ],
                      ),
                    ),

                    const Spacer(),

                    // Center Cinematic Poster Showcase
                    ScaleTransition(
                      scale: Tween<double>(begin: 1.0, end: 1.05).animate(
                        CurvedAnimation(
                          parent: _revealController,
                          curve: Curves.easeOutBack,
                        ),
                      ),
                      child: Container(
                        width: cardWidth,
                        height: cardHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _isFinalSelected
                                ? const Color(0xFF00E5A0).withValues(alpha: 0.8)
                                : const Color(0xFFFF9F1C).withValues(alpha: 0.45),
                            width: _isFinalSelected ? 2.5 : 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.65),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                            BoxShadow(
                              color: (_isFinalSelected
                                      ? const Color(0xFF00E5A0)
                                      : const Color(0xFFFF9F1C))
                                  .withValues(alpha: _isFinalSelected ? 0.35 : 0.18),
                              blurRadius: _isFinalSelected ? 30 : 16,
                              spreadRadius: _isFinalSelected ? 2 : 0,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Poster Image
                              if (hasValidPoster)
                                CachedNetworkImage(
                                  imageUrl: 'https://image.tmdb.org/t/p/w500$posterPath',
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    color: const Color(0xFF141722),
                                  ),
                                  errorWidget: (context, url, err) => Container(
                                    color: const Color(0xFF141722),
                                    child: const Center(
                                      child: Icon(
                                        Icons.movie_rounded,
                                        color: Colors.white24,
                                        size: 40,
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Container(
                                  color: const Color(0xFF141722),
                                  child: const Center(
                                    child: Icon(
                                      Icons.movie_rounded,
                                      color: Colors.white24,
                                      size: 40,
                                    ),
                                  ),
                                ),

                              // Top-right Rating Chip
                              if (rating > 0)
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.75),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: const Color(0xFFFFB800).withValues(alpha: 0.6),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.star_rounded,
                                          color: Color(0xFFFFB800),
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          ratingStr,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                              // Bottom Vignette Shadow
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                height: 60,
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: [
                                        Colors.black.withValues(alpha: 0.7),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const Spacer(),

                    // Movie Title
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: wt * 0.08),
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _isFinalSelected ? const Color(0xFF00E5A0) : Colors.white,
                          fontSize: (ht * 0.024).clamp(16.0, 21.0),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          shadows: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.8),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Subtitle / Status
                    Text(
                      _statusText,
                      style: TextStyle(
                        color: _isFinalSelected
                            ? Colors.white.withValues(alpha: 0.9)
                            : const Color(0xFFFF9F1C),
                        fontSize: (ht * 0.017).clamp(12.0, 14.5),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),

                    SizedBox(height: (ht * 0.025).clamp(12.0, 24.0)),

                    // 5-Second Animated Progress Bar
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: wt * 0.16),
                      child: Column(
                        children: [
                          Container(
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: AnimatedBuilder(
                              animation: _progressController,
                              builder: (context, child) {
                                return FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: _progressController.value,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFFFF9F1C),
                                          Color(0xFF00E5A0),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(3),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF00E5A0).withValues(alpha: 0.5),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isFinalSelected
                                ? 'Opening movie details...'
                                : 'Selecting in $_secondsLeft s',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
