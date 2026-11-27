import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

class MrdbSplashScreen extends StatefulWidget {
  const MrdbSplashScreen({
    super.key,
    required this.nextScreen,
    this.onInit,
    this.minDisplayDuration = const Duration(milliseconds: 1600),
  });

  /// Screen to navigate to once initialization and minimum delay complete.
  final Widget nextScreen;

  /// Optional async startup work (e.g., loading cache, TMDB config, or auth).
  final Future<void> Function()? onInit;

  /// Minimum time the splash screen stays visible so transitions don't flash.
  final Duration minDisplayDuration;

  @override
  State<MrdbSplashScreen> createState() => _MrdbSplashScreenState();
}

class _MrdbSplashScreenState extends State<MrdbSplashScreen>
    with TickerProviderStateMixin {
  // MRDb obsidian cinema palette matching Home & App Icon
  static const Color _bgColor = Color(0xFF06080F);
  static const Color _accentEmerald = Color(0xFF00E5A0);
  static const Color _accentCyan = Color(0xFF00B0FF);
  static const Color _accentGold = Color(0xFFFFCA64);
  static const Color _accentRose = Color(0xFFFF5E97);
  static const Color _accentViolet = Color(0xFF7C5CFF);

  static const List<_SplashFeatureTag> _featureTags = [
    _SplashFeatureTag(
      icon: Icons.explore_rounded,
      label: 'Discover Movies',
      color: _accentEmerald,
    ),
    _SplashFeatureTag(
      icon: Icons.star_rounded,
      label: 'Ratings & Soundtracks',
      color: _accentGold,
    ),
    _SplashFeatureTag(
      icon: Icons.play_circle_rounded,
      label: 'Trailers & HD Stream',
      color: _accentCyan,
    ),
  ];

  late final AnimationController _introController;
  late final AnimationController _ambientController;
  late final AnimationController _progressController;
  late final AnimationController _exitController;

  late final Animation<double> _heroScale;
  late final Animation<double> _heroOpacity;
  late final Animation<double> _cardsFanProgress;
  late final Animation<double> _textOpacity;
  late final Animation<Offset> _textSlide;
  late final Animation<double> _exitProgress;

  Timer? _tagTimer;
  int _currentTagIndex = 0;
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();

    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..forward();

    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat();

    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );

    _heroScale = Tween<double>(begin: 0.78, end: 1.0).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
      ),
    );

    _heroOpacity = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.0, 0.42, curve: Curves.easeOut),
    );

    _cardsFanProgress = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.18, 0.80, curve: Curves.easeOutBack),
    );

    _textOpacity = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.32, 0.85, curve: Curves.easeOut),
    );

    _textSlide = Tween<Offset>(
      begin: const Offset(0.0, 0.16),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _introController,
        curve: const Interval(0.32, 0.90, curve: Curves.easeOutCubic),
      ),
    );

    _exitProgress = CurvedAnimation(
      parent: _exitController,
      curve: Curves.easeOutCubic,
    );

    _tagTimer = Timer.periodic(const Duration(milliseconds: 850), (_) {
      if (!mounted || _isNavigating) return;
      setState(() {
        _currentTagIndex = (_currentTagIndex + 1) % _featureTags.length;
      });
    });

    _initializeAndNavigate();
  }

  Future<void> _initializeAndNavigate() async {
    try {
      await Future.wait([
        Future<void>.delayed(widget.minDisplayDuration),
        if (widget.onInit != null)
          widget.onInit!().timeout(
            const Duration(seconds: 6),
            onTimeout: () {
              debugPrint('MRDb splash init timed out, proceeding to app');
            },
          ),
      ]);
    } catch (e) {
      debugPrint('MRDb splash init error: $e');
    }

    if (!mounted || _isNavigating) return;
    _isNavigating = true;
    _tagTimer?.cancel();
    _exitController.forward();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 580),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (context, animation, secondaryAnimation) =>
            widget.nextScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final fade = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.05, 0.85, curve: Curves.easeOut),
          );
          final motion = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );

          return FadeTransition(
            opacity: fade,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.025),
                end: Offset.zero,
              ).animate(motion),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1.0).animate(motion),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _tagTimer?.cancel();
    _introController.dispose();
    _ambientController.dispose();
    _progressController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeTag = _featureTags[_currentTagIndex];

    return AnimatedBuilder(
      animation: _exitProgress,
      builder: (context, child) {
        final exitT = _exitProgress.value;
        final bg = Color.lerp(_bgColor, Colors.black, exitT)!;

        return Scaffold(
          backgroundColor: bg,
          body: Opacity(
            opacity: (1.0 - exitT).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -10.0 * exitT),
              child: Transform.scale(
                scale: 1.0 + (0.035 * exitT),
                child: child,
              ),
            ),
          ),
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Soft cinema ambient aura echoing MRDb's icon & brand colors
          _CinemaAmbientBackdrop(
            ambientAnimation: _ambientController,
            accentColor: activeTag.color,
          ),

          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MrdbCinemaDeckEmblem(
                            heroScale: _heroScale,
                            heroOpacity: _heroOpacity,
                            cardsFanProgress: _cardsFanProgress,
                            ambientAnimation: _ambientController,
                          ),
                          const SizedBox(height: 26),
                          FadeTransition(
                            opacity: _textOpacity,
                            child: SlideTransition(
                              position: _textSlide,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _MrdbWordmark(),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Movie Research Database',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.62,
                                      ),
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.7,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  _FriendlyCapabilityPill(
                                    item: activeTag,
                                    tagIndex: _currentTagIndex,
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

                // Friendly minimalist bottom loader
                FadeTransition(
                  opacity: _textOpacity,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 34),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Getting things ready',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.42),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _CinemaShimmerBar(
                          controller: _progressController,
                          primaryColor: _accentEmerald,
                          secondaryColor: _accentCyan,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SplashFeatureTag {
  const _SplashFeatureTag({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;
}

class _CinemaAmbientBackdrop extends StatelessWidget {
  const _CinemaAmbientBackdrop({
    required this.ambientAnimation,
    required this.accentColor,
  });

  final Animation<double> ambientAnimation;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: ambientAnimation,
        builder: (context, _) {
          final pulse = Curves.easeInOutSine.transform(ambientAnimation.value);

          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.0, -0.14),
                    radius: 0.85 + (0.08 * pulse),
                    colors: [
                      _MrdbSplashScreenState._accentViolet.withValues(
                        alpha: 0.14 + (0.05 * pulse),
                      ),
                      _MrdbSplashScreenState._accentRose.withValues(
                        alpha: 0.05 + (0.03 * pulse),
                      ),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 450),
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.0, -0.05),
                    radius: 0.58 + (0.06 * pulse),
                    colors: [
                      accentColor.withValues(alpha: 0.09 + (0.04 * pulse)),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MrdbCinemaDeckEmblem extends StatelessWidget {
  const _MrdbCinemaDeckEmblem({
    required this.heroScale,
    required this.heroOpacity,
    required this.cardsFanProgress,
    required this.ambientAnimation,
  });

  final Animation<double> heroScale;
  final Animation<double> heroOpacity;
  final Animation<double> cardsFanProgress;
  final Animation<double> ambientAnimation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        heroScale,
        heroOpacity,
        cardsFanProgress,
        ambientAnimation,
      ]),
      builder: (context, _) {
        final fan = cardsFanProgress.value;
        final floatWave = math.sin(ambientAnimation.value * math.pi);
        final glowPulse = Curves.easeInOutSine.transform(ambientAnimation.value);

        return SizedBox(
          width: 196,
          height: 118,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // Left fanned movie-rating poster card
              Opacity(
                opacity: fan.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(-38.0 * fan, 6.0 * fan + (1.5 * floatWave)),
                  child: Transform.rotate(
                    angle: -0.22 * fan,
                    child: const _GhostPosterCard(
                      gradientColors: [Color(0xFF171E3A), Color(0xFF0D1122)],
                      rimColor: Color(0xFFFF7A9E),
                      badgeIcon: Icons.star_rounded,
                      badgeColor: _MrdbSplashScreenState._accentGold,
                      alignLeftBadge: true,
                    ),
                  ),
                ),
              ),

              // Right fanned trailer/stream poster card
              Opacity(
                opacity: fan.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(38.0 * fan, 6.0 * fan - (1.5 * floatWave)),
                  child: Transform.rotate(
                    angle: 0.22 * fan,
                    child: const _GhostPosterCard(
                      gradientColors: [Color(0xFF1B1638), Color(0xFF0E1020)],
                      rimColor: _MrdbSplashScreenState._accentEmerald,
                      badgeIcon: Icons.play_arrow_rounded,
                      badgeColor: _MrdbSplashScreenState._accentEmerald,
                      alignLeftBadge: false,
                    ),
                  ),
                ),
              ),

              // Center MRDb Hero Emblem Card
              FadeTransition(
                opacity: heroOpacity,
                child: Transform.translate(
                  offset: Offset(0, -2.5 * floatWave),
                  child: Transform.scale(
                    scale: heroScale.value,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            _MrdbSplashScreenState._accentEmerald.withValues(
                              alpha: 0.42 + (0.18 * glowPulse),
                            ),
                            _MrdbSplashScreenState._accentRose.withValues(
                              alpha: 0.35 + (0.15 * glowPulse),
                            ),
                            _MrdbSplashScreenState._accentCyan.withValues(
                              alpha: 0.38,
                            ),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _MrdbSplashScreenState._accentEmerald
                                .withValues(alpha: 0.14 + (0.10 * glowPulse)),
                            blurRadius: 22 + (8 * glowPulse),
                            spreadRadius: 1,
                          ),
                          BoxShadow(
                            color: _MrdbSplashScreenState._accentRose
                                .withValues(alpha: 0.12 + (0.08 * glowPulse)),
                            blurRadius: 24,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(1.6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24.5),
                        child: Container(
                          color: const Color(0xFF0A0F24),
                          child: Image.asset(
                            'assets/images/mrdb_logo.png',
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                const _FallbackMrdbCrest(),
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
    );
  }
}

class _GhostPosterCard extends StatelessWidget {
  const _GhostPosterCard({
    required this.gradientColors,
    required this.rimColor,
    required this.badgeIcon,
    required this.badgeColor,
    required this.alignLeftBadge,
  });

  final List<Color> gradientColors;
  final Color rimColor;
  final IconData badgeIcon;
  final Color badgeColor;
  final bool alignLeftBadge;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 66,
      height: 92,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        border: Border.all(
          color: rimColor.withValues(alpha: 0.40),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment:
            alignLeftBadge ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: badgeColor.withValues(alpha: 0.35),
                width: 0.8,
              ),
            ),
            child: Icon(badgeIcon, color: badgeColor, size: 13),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 3.5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 22,
                height: 3,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FallbackMrdbCrest extends StatelessWidget {
  const _FallbackMrdbCrest();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF141B38), Color(0xFF0A0D1D)],
        ),
      ),
      child: Center(
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [
              _MrdbSplashScreenState._accentEmerald,
              _MrdbSplashScreenState._accentCyan,
            ],
          ).createShader(bounds),
          child: const Icon(
            Icons.movie_filter_rounded,
            color: Colors.white,
            size: 42,
          ),
        ),
      ),
    );
  }
}

class _MrdbWordmark extends StatelessWidget {
  const _MrdbWordmark();

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: const TextSpan(
        children: [
          TextSpan(
            text: 'MR',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
          TextSpan(
            text: 'Db',
            style: TextStyle(
              color: _MrdbSplashScreenState._accentEmerald,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendlyCapabilityPill extends StatelessWidget {
  const _FriendlyCapabilityPill({
    required this.item,
    required this.tagIndex,
  });

  final _SplashFeatureTag item;
  final int tagIndex;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF111524).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: item.color.withValues(alpha: 0.30),
          width: 1,
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.2),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        ),
        child: Row(
          key: ValueKey<int>(tagIndex),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, size: 14, color: item.color),
            const SizedBox(width: 6),
            Text(
              item.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.86),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CinemaShimmerBar extends StatelessWidget {
  const _CinemaShimmerBar({
    required this.controller,
    required this.primaryColor,
    required this.secondaryColor,
  });

  final AnimationController controller;
  final Color primaryColor;
  final Color secondaryColor;

  static const double _trackWidth = 104;
  static const double _trackHeight = 3.5;
  static const double _pillWidth = 40;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: _trackWidth,
        height: _trackHeight,
        child: Stack(
          children: [
            Container(color: Colors.white.withValues(alpha: 0.10)),
            AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final curved = Curves.easeInOutCubic.transform(
                  controller.value,
                );
                final leftOffset =
                    -_pillWidth + (_trackWidth + _pillWidth) * curved;

                return Positioned(
                  left: leftOffset,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: _pillWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: [
                          primaryColor.withValues(alpha: 0.15),
                          primaryColor,
                          secondaryColor,
                          secondaryColor.withValues(alpha: 0.15),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
