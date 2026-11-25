import 'dart:async';
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
  static const Color _bgColor = Color(0xFF0E1220);
  static const Color _surfaceColor = Color(0xFF171C30);

  static const List<_SplashIconItem> _icons = [
    _SplashIconItem(Icons.search_rounded, Color(0xFF64D2FF)),
    _SplashIconItem(Icons.star_rounded, Color(0xFFFFCA64)),
    _SplashIconItem(Icons.play_arrow_rounded, Color(0xFFFF6B8B)),
    _SplashIconItem(Icons.people_alt_rounded, Color(0xFFB388FF)),
  ];

  late final AnimationController _glowController;
  late final Animation<double> _glowAnimation;
  late final AnimationController _progressController;

  Timer? _iconTimer;
  int _currentIconIndex = 0;

  @override
  void initState() {
    super.initState();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _glowAnimation = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeInOutSine,
    );

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();

    _iconTimer = Timer.periodic(const Duration(milliseconds: 650), (_) {
      if (!mounted) return;
      setState(() {
        _currentIconIndex = (_currentIconIndex + 1) % _icons.length;
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

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 1800),
        reverseTransitionDuration: const Duration(milliseconds: 1800),
        pageBuilder: (context, animation, secondaryAnimation) =>
            widget.nextScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.fastOutSlowIn,
          );

          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _iconTimer?.cancel();
    _glowController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeItem = _icons[_currentIconIndex];

    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Stack(
          children: [
            // Centre loader + brand title
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BreathingIconBox(
                    glowAnimation: _glowAnimation,
                    surfaceColor: _surfaceColor,
                    activeItem: activeItem,
                    iconIndex: _currentIconIndex,
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'MRDb',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.0,
                    ),
                  ),
                ],
              ),
            ),

            // Bottom minimalist indeterminate pill progress bar
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: _SlidingPillProgressBar(
                  controller: _progressController,
                  accentColor: activeItem.color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplashIconItem {
  const _SplashIconItem(this.icon, this.color);

  final IconData icon;
  final Color color;
}

class _BreathingIconBox extends StatelessWidget {
  const _BreathingIconBox({
    required this.glowAnimation,
    required this.surfaceColor,
    required this.activeItem,
    required this.iconIndex,
  });

  final Animation<double> glowAnimation;
  final Color surfaceColor;
  final _SplashIconItem activeItem;
  final int iconIndex;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: glowAnimation,
      builder: (context, child) {
        final t = glowAnimation.value;
        final borderColor = Color.lerp(
          Colors.white12,
          activeItem.color.withValues(alpha: 0.45),
          t,
        )!;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: activeItem.color.withValues(alpha: 0.10 + (0.16 * t)),
                blurRadius: 18 + (12 * t),
                spreadRadius: 1.5 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.72, end: 1.0).animate(animation),
                child: child,
              ),
            );
          },
          child: Icon(
            activeItem.icon,
            key: ValueKey<int>(iconIndex),
            color: activeItem.color,
            size: 40,
          ),
        ),
      ),
    );
  }
}

class _SlidingPillProgressBar extends StatelessWidget {
  const _SlidingPillProgressBar({
    required this.controller,
    required this.accentColor,
  });

  final AnimationController controller;
  final Color accentColor;

  static const double _trackWidth = 72;
  static const double _trackHeight = 3;
  static const double _pillWidth = 28;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: _trackWidth,
        height: _trackHeight,
        child: Stack(
          children: [
            Container(color: Colors.white12),
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
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: _pillWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: [
                          accentColor.withValues(alpha: 0.15),
                          accentColor,
                          accentColor.withValues(alpha: 0.15),
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
