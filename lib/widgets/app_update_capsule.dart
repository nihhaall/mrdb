import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/services/app_update_service.dart';

/// Shared visibility & expansion state for [AppUpdateCapsule].
class AppUpdateCapsuleController extends ChangeNotifier {
  AppUpdateCapsuleController({
    bool visible = false,
    bool expanded = false,
  })  : _isVisible = visible,
        _isExpanded = expanded;

  static final AppUpdateCapsuleController instance =
      AppUpdateCapsuleController();

  bool _isVisible;
  bool _isExpanded;

  bool get isVisible => _isVisible;
  bool get isExpanded => _isExpanded;

  void reveal({bool expanded = false}) {
    if (_isVisible && _isExpanded == expanded) return;
    _isVisible = true;
    _isExpanded = expanded;
    notifyListeners();
  }

  void expand() {
    if (_isVisible && _isExpanded) return;
    _isVisible = true;
    _isExpanded = true;
    notifyListeners();
  }

  void collapse() {
    if (!_isExpanded) return;
    _isExpanded = false;
    notifyListeners();
  }

  void dismiss() {
    if (!_isVisible && !_isExpanded) return;
    _isVisible = false;
    _isExpanded = false;
    notifyListeners();
  }
}

/// Unique, non-intrusive floating update capsule that morphs smoothly
/// between a compact satellite pill and a clean expandable update card.
class AppUpdateCapsule extends StatefulWidget {
  final AppUpdateService? service;
  final AppUpdateCapsuleController? controller;
  final bool hideCompact;

  const AppUpdateCapsule({
    super.key,
    this.service,
    this.controller,
    this.hideCompact = false,
  });

  @override
  State<AppUpdateCapsule> createState() => _AppUpdateCapsuleState();
}

class _AppUpdateCapsuleState extends State<AppUpdateCapsule>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const Color _kSurface = Color(0xFF141824);
  static const Color _kSurfaceDeep = Color(0xFF0E111B);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kWarn = Color(0xFFFFB74D);
  static const Color _kError = Color(0xFFFF6B6B);

  late final AnimationController _pulseController;
  late final AnimationController _visibilityController;
  late final AnimationController _expandController;
  late final Animation<double> _visibilityFade;
  late final Animation<double> _visibilityScale;
  late final Animation<Offset> _visibilitySlide;
  late final Animation<double> _scrimAnim;

  double _dragOffsetX = 0;

  AppUpdateService get _service => widget.service ?? AppUpdateService.instance;
  AppUpdateCapsuleController get _controller =>
      widget.controller ?? AppUpdateCapsuleController.instance;

  bool get _shouldBeVisible {
    final state = _service.state;
    final info = state.info;
    final hasUpdate = state.hasAvailableUpdate && info != null;
    if (!hasUpdate || !_controller.isVisible) return false;
    final isExpanded = _controller.isExpanded || info.forceUpdate;
    if (!isExpanded && widget.hideCompact) return false;
    return true;
  }

  bool get _shouldBeExpanded {
    final state = _service.state;
    final info = state.info;
    if (!state.hasAvailableUpdate || info == null || !_controller.isVisible) {
      return false;
    }
    return _controller.isExpanded || info.forceUpdate;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _visibilityController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 220),
      value: _shouldBeVisible ? 1.0 : 0.0,
    );
    _visibilityFade = CurvedAnimation(
      parent: _visibilityController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _visibilityScale = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(
        parent: _visibilityController,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    _visibilitySlide = Tween<Offset>(
      begin: const Offset(0, 0.28),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _visibilityController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 240),
      value: _shouldBeExpanded ? 1.0 : 0.0,
    );
    _scrimAnim = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _service.addListener(_syncAnimations);
    _controller.addListener(_syncAnimations);
  }

  @override
  void didUpdateWidget(covariant AppUpdateCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      (oldWidget.service ?? AppUpdateService.instance)
          .removeListener(_syncAnimations);
      _service.addListener(_syncAnimations);
    }
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? AppUpdateCapsuleController.instance)
          .removeListener(_syncAnimations);
      _controller.addListener(_syncAnimations);
    }
    _syncAnimations();
  }

  void _syncAnimations() {
    if (!mounted) return;
    if (_shouldBeVisible) {
      _visibilityController.forward();
    } else {
      _visibilityController.reverse();
    }
    if (_shouldBeExpanded) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_syncAnimations);
    _controller.removeListener(_syncAnimations);
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _visibilityController.dispose();
    _expandController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _service.state.phase == AppUpdatePhase.needsPermission) {
      _service.retryInstallOrCheckPermission();
    }
  }

  Future<void> _onSkipVersion(AppUpdateInfo info) async {
    HapticFeedback.selectionClick();
    await _service.skipThisVersion(info);
    _controller.dismiss();
  }

  Future<void> _onOpenBrowser(AppUpdateInfo info) async {
    HapticFeedback.lightImpact();
    await _service.openDownloadInBrowser(info);
  }

  Color _accentForPhase(AppUpdatePhase phase, bool forceUpdate) {
    return switch (phase) {
      AppUpdatePhase.needsPermission => _kWarn,
      AppUpdatePhase.error => _kError,
      _ => forceUpdate ? _kWarn : _kAccent,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _service,
        _controller,
        _visibilityController,
        _expandController,
      ]),
      builder: (context, _) {
        final state = _service.state;
        final info = state.info;
        final hasUpdate = state.hasAvailableUpdate && info != null;

        if (!hasUpdate || _visibilityController.isDismissed) {
          return const SizedBox.shrink();
        }

        final phase = state.phase;
        final isExpanded = _controller.isExpanded || info.forceUpdate;
        final accent = _accentForPhase(phase, info.forceUpdate);
        final isForce = info.forceUpdate;
        final scrimValue = _scrimAnim.value;
        final isInteractive = _shouldBeVisible;

        return PopScope(
          canPop: !isForce && !isExpanded,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && !isForce && isExpanded) {
              _controller.collapse();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Animated backdrop scrim & blur while expanded
              if (scrimValue > 0.005)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !isExpanded || !isInteractive,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: isForce
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              _controller.collapse();
                            },
                      child: ClipRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: (isForce ? 5.0 : 2.5) * scrimValue,
                            sigmaY: (isForce ? 5.0 : 2.5) * scrimValue,
                          ),
                          child: ColoredBox(
                            color: Colors.black.withValues(
                              alpha: (isForce ? 0.72 : 0.45) * scrimValue,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // Morphing Capsule / Floating Card with Open & Close Transitions
              Align(
                alignment: isForce ? Alignment.center : Alignment.bottomCenter,
                child: SafeArea(
                  top: isForce,
                  child: IgnorePointer(
                    ignoring: !isInteractive,
                    child: FadeTransition(
                      opacity: _visibilityFade,
                      child: SlideTransition(
                        position: _visibilitySlide,
                        child: ScaleTransition(
                          scale: _visibilityScale,
                          alignment: isForce
                              ? Alignment.center
                              : Alignment.bottomCenter,
                          child: AnimatedPadding(
                            duration: const Duration(milliseconds: 280),
                            curve: Curves.easeOutCubic,
                            padding: isExpanded
                                ? EdgeInsets.fromLTRB(
                                    16,
                                    16,
                                    16,
                                    isForce ? 16 : 86,
                                  )
                                : const EdgeInsets.fromLTRB(20, 0, 20, 86),
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.bottomCenter,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                reverseDuration:
                                    const Duration(milliseconds: 200),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                layoutBuilder: (currentChild, previousChildren) {
                                  return Stack(
                                    alignment: isForce
                                        ? Alignment.center
                                        : Alignment.bottomCenter,
                                    children: [
                                      ...previousChildren,
                                      if (currentChild != null) currentChild,
                                    ],
                                  );
                                },
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: Tween<double>(
                                        begin: 0.93,
                                        end: 1.0,
                                      ).animate(animation),
                                      alignment: isForce
                                          ? Alignment.center
                                          : Alignment.bottomCenter,
                                      child: child,
                                    ),
                                  );
                                },
                                child: isExpanded
                                    ? _buildExpandedCard(
                                        info,
                                        state,
                                        phase,
                                        accent,
                                      )
                                    : _buildCompactPill(
                                        info,
                                        state,
                                        phase,
                                        accent,
                                      ),
                              ),
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
    );
  }

  // ── Compact Floating Capsule ──────────────────────────────────────────────
  Widget _buildCompactPill(
    AppUpdateInfo info,
    AppUpdateState state,
    AppUpdatePhase phase,
    Color accent,
  ) {
    final isBusy = state.isDownloadingOrVerifying;
    final canDismiss = !info.forceUpdate && !isBusy;

    final String title;
    final String subtitle;
    final String actionLabel;
    final VoidCallback onAction;

    switch (phase) {
      case AppUpdatePhase.downloading:
        final pct = state.progress != null
            ? '${(state.progress! * 100).round()}%'
            : '...';
        title = 'Updating $pct';
        subtitle = state.formattedSpeed.isNotEmpty
            ? state.formattedSpeed
            : state.formattedProgress;
        actionLabel = '';
        onAction = () {
          HapticFeedback.selectionClick();
          _controller.expand();
        };
      case AppUpdatePhase.verifying:
        title = 'Checking...';
        subtitle = 'Almost ready';
        actionLabel = '';
        onAction = () {
          HapticFeedback.selectionClick();
          _controller.expand();
        };
      case AppUpdatePhase.needsPermission:
        title = 'Allow install';
        subtitle = 'Tap to finish';
        actionLabel = 'Allow';
        onAction = () {
          HapticFeedback.mediumImpact();
          _service.openPermissionSettings();
        };
      case AppUpdatePhase.readyToInstall:
      case AppUpdatePhase.installing:
        title = 'Ready v${info.latestVersion}';
        subtitle = 'Tap to install';
        actionLabel = 'Install';
        onAction = () {
          HapticFeedback.mediumImpact();
          _service.retryInstallOrCheckPermission();
        };
      case AppUpdatePhase.error:
        title = 'Update paused';
        subtitle = 'Tap for details';
        actionLabel = 'Retry';
        onAction = () {
          HapticFeedback.mediumImpact();
          _service.startUpdate(info);
        };
      case AppUpdatePhase.available:
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
        title = 'v${info.latestVersion}';
        subtitle = 'What\'s new';
        actionLabel = 'Update';
        onAction = () {
          HapticFeedback.mediumImpact();
          _service.startUpdate(info);
        };
    }

    final double progressFill = switch (phase) {
      AppUpdatePhase.downloading => (state.progress ?? 0.0).clamp(0.0, 1.0),
      AppUpdatePhase.verifying => 1.0,
      _ => 0.0,
    };

    return GestureDetector(
      key: const ValueKey('update_compact_pill'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: canDismiss
          ? (details) {
              setState(() {
                _dragOffsetX = (_dragOffsetX + details.delta.dx).clamp(
                  -140.0,
                  140.0,
                );
              });
            }
          : null,
      onHorizontalDragEnd: canDismiss
          ? (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (_dragOffsetX.abs() > 56 || velocity.abs() > 450) {
                HapticFeedback.lightImpact();
                setState(() => _dragOffsetX = 0);
                _controller.dismiss();
              } else {
                setState(() => _dragOffsetX = 0);
              }
            }
          : null,
      onTap: () {
        HapticFeedback.selectionClick();
        _controller.expand();
      },
      child: Transform.translate(
        offset: Offset(_dragOffsetX, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 264),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: accent.withValues(alpha: 0.45),
                width: 1.15,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.16),
                  blurRadius: 16,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.65),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(27),
              child: Stack(
                children: [
                  // Base dark capsule background
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFF1A1F30).withValues(alpha: 0.97),
                            _kSurface.withValues(alpha: 0.97),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Live liquid download progress fill inside the pill
                  if (isBusy)
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: progressFill,
                          heightFactor: 1.0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Slim luminous progress strip at the bottom of the pill
                  if (isBusy)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 2.5,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: progressFill,
                          heightFactor: 1.0,
                          child: ColoredBox(color: accent),
                        ),
                      ),
                    ),

                  // Foreground pill contents
                  Padding(
                    padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildPillLeadingIcon(phase, state, accent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                ),
                              ),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.58),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (isBusy)
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.keyboard_arrow_up_rounded,
                              color: accent,
                              size: 16,
                            ),
                          )
                        else
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onAction,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 6.5,
                              ),
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                actionLabel,
                                style: const TextStyle(
                                  color: Color(0xFF090C12),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.1,
                                ),
                              ),
                            ),
                          ),
                        if (canDismiss) ...[
                          const SizedBox(width: 2),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              HapticFeedback.lightImpact();
                              _controller.dismiss();
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white38,
                                size: 15,
                              ),
                            ),
                          ),
                        ],
                      ],
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

  Widget _buildPillLeadingIcon(
    AppUpdatePhase phase,
    AppUpdateState state,
    Color accent,
  ) {
    if (phase == AppUpdatePhase.downloading ||
        phase == AppUpdatePhase.verifying) {
      return SizedBox(
        width: 30,
        height: 30,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: phase == AppUpdatePhase.verifying ? null : state.progress,
              strokeWidth: 2.3,
              color: accent,
              backgroundColor: Colors.white12,
            ),
            Icon(
              phase == AppUpdatePhase.verifying
                  ? Icons.verified_rounded
                  : Icons.arrow_downward_rounded,
              color: accent,
              size: 13,
            ),
          ],
        ),
      );
    }

    final IconData icon = switch (phase) {
      AppUpdatePhase.needsPermission => Icons.lock_open_rounded,
      AppUpdatePhase.readyToInstall ||
      AppUpdatePhase.installing => Icons.install_mobile_rounded,
      AppUpdatePhase.error => Icons.refresh_rounded,
      _ => Icons.auto_awesome_rounded,
    };

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final glowAlpha = 0.14 + (_pulseController.value * 0.14);
        return Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: glowAlpha),
            shape: BoxShape.circle,
            border: Border.all(
              color: accent.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: child,
        );
      },
      child: Icon(icon, color: accent, size: 15),
    );
  }

  // ── Expanded Floating Update Card ─────────────────────────────────────────
  Widget _buildExpandedCard(
    AppUpdateInfo info,
    AppUpdateState state,
    AppUpdatePhase phase,
    Color accent,
  ) {
    final knownBytes =
        state.totalBytes > 0 ? state.totalBytes : (info.fileSizeBytes ?? 0);

    final (IconData icon, String title) = switch (phase) {
      AppUpdatePhase.needsPermission => (
          Icons.lock_open_rounded,
          'Allow App Installs',
        ),
      AppUpdatePhase.readyToInstall => (
          Icons.install_mobile_rounded,
          'Ready to Install',
        ),
      AppUpdatePhase.installing => (
          Icons.install_mobile_rounded,
          'Opening Installer...',
        ),
      AppUpdatePhase.downloading => (
          Icons.downloading_rounded,
          'Downloading Update',
        ),
      AppUpdatePhase.verifying => (
          Icons.verified_user_rounded,
          'Checking File...',
        ),
      AppUpdatePhase.error => (
          Icons.error_outline_rounded,
          'Update Paused',
        ),
      _ => (
          Icons.auto_awesome_rounded,
          info.forceUpdate
              ? 'Update Required'
              : 'MRDb v${info.latestVersion} is Ready',
        ),
    };

    final Color secondaryGrad = phase == AppUpdatePhase.needsPermission ||
            info.forceUpdate
        ? const Color(0xFFFF8A3D)
        : (phase == AppUpdatePhase.error
            ? const Color(0xFFFF4D6D)
            : const Color(0xFF00C2FF));

    return ConstrainedBox(
      key: const ValueKey('update_expanded_card'),
      constraints: const BoxConstraints(maxWidth: 380),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: accent.withValues(alpha: 0.42),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.18),
              blurRadius: 28,
              spreadRadius: 1,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.78),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: Stack(
            children: [
              // Base dark obsidian surface
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF181D2D), Color(0xFF0E111B)],
                    ),
                  ),
                ),
              ),

              // Subtle top-left spotlight glow
              Positioned(
                top: -45,
                left: -35,
                width: 190,
                height: 150,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [
                          accent.withValues(alpha: 0.18),
                          accent.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Top luminous hairline accent beam
              Positioned(
                top: 0,
                left: 24,
                right: 24,
                height: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accent.withValues(alpha: 0.0),
                        accent.withValues(alpha: 0.75),
                        secondaryGrad.withValues(alpha: 0.6),
                        accent.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),

              // Card Contents
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                accent.withValues(alpha: 0.48),
                                secondaryGrad.withValues(alpha: 0.18),
                              ],
                            ),
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF121724),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Icon(icon, color: accent, size: 22),
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.25,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: accent.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: accent.withValues(alpha: 0.28),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Text(
                                      'v${info.currentVersion}  →  v${info.latestVersion}',
                                      style: TextStyle(
                                        color: accent,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (knownBytes > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.07),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        AppUpdateState.formatBytes(knownBytes),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  if (info.forceUpdate)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _kWarn.withValues(alpha: 0.18),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: _kWarn.withValues(alpha: 0.35),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: const Text(
                                        'Required',
                                        style: TextStyle(
                                          color: _kWarn,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (!info.forceUpdate) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              _controller.collapse();
                            },
                            child: Container(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.09),
                                ),
                              ),
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white70,
                                size: 19,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),

                    const SizedBox(height: 15),

                    // Dynamic Body
                    _buildExpandedBody(
                      info,
                      state,
                      phase,
                      accent,
                      secondaryGrad,
                    ),

                    const SizedBox(height: 16),

                    // Simple Friendly Actions
                    _buildExpandedActions(info, phase, accent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedBody(
    AppUpdateInfo info,
    AppUpdateState state,
    AppUpdatePhase phase,
    Color accent,
    Color secondaryGrad,
  ) {
    switch (phase) {
      case AppUpdatePhase.downloading:
      case AppUpdatePhase.verifying:
        final isVerifying = phase == AppUpdatePhase.verifying;
        final pct =
            state.progress != null ? '${(state.progress! * 100).round()}%' : '';
        final progressVal = isVerifying ? null : state.progress;

        return Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: _kSurfaceDeep.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (progressVal != null)
                Container(
                  height: 8,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progressVal.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [accent, secondaryGrad],
                        ),
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.45),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: null,
                    minHeight: 8,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      isVerifying
                          ? 'Checking file...'
                          : (pct.isNotEmpty ? pct : 'Starting...'),
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      state.formattedSpeed.isNotEmpty
                          ? '${state.formattedProgress}  •  ${state.formattedSpeed}'
                          : state.formattedProgress,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case AppUpdatePhase.needsPermission:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _kWarn.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kWarn.withValues(alpha: 0.28)),
          ),
          child: Text(
            'Turn on "Allow from this source" in Settings, then return here — MRDb installs automatically.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 12.8,
              height: 1.42,
              fontWeight: FontWeight.w500,
            ),
          ),
        );

      case AppUpdatePhase.readyToInstall:
      case AppUpdatePhase.installing:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle_rounded, color: accent, size: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  phase == AppUpdatePhase.installing
                      ? 'Tap "Install" on the Android popup to finish updating.'
                      : 'Update is ready! Tap Install Now to apply it.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 12.8,
                    height: 1.38,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );

      case AppUpdatePhase.error:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _kError.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kError.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded, color: _kError, size: 18),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  state.errorMessage ??
                      'Could not complete the update. Please try again.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12.8,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );

      case AppUpdatePhase.available:
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: _kSurfaceDeep.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 13,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [accent, secondaryGrad],
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    "What's New",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 115),
                child: SingleChildScrollView(
                  child: Text(
                    info.releaseNotes,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 13,
                      height: 1.48,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildExpandedActions(
    AppUpdateInfo info,
    AppUpdatePhase phase,
    Color accent,
  ) {
    switch (phase) {
      case AppUpdatePhase.downloading:
      case AppUpdatePhase.verifying:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _service.cancelDownload();
                },
                style: _secondaryButtonStyle(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (!info.forceUpdate) ...[
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _controller.collapse();
                  },
                  icon: const Icon(Icons.minimize_rounded, size: 18),
                  label: const Text(
                    'Keep in Pill',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                  ),
                  style: _primaryButtonStyle(bg: accent),
                ),
              ),
            ],
          ],
        );

      case AppUpdatePhase.needsPermission:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (!info.forceUpdate) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _controller.collapse();
                      },
                      style: _secondaryButtonStyle(),
                      child: const Text(
                        'Later',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      _service.openPermissionSettings();
                    },
                    icon: const Icon(Icons.settings_rounded, size: 17),
                    label: const Text(
                      'Open Settings',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    style: _primaryButtonStyle(bg: _kWarn),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                _service.retryInstallOrCheckPermission();
              },
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Already enabled? Continue',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );

      case AppUpdatePhase.readyToInstall:
      case AppUpdatePhase.installing:
        return Row(
          children: [
            if (!info.forceUpdate) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _controller.dismiss();
                  },
                  style: _secondaryButtonStyle(),
                  child: const Text(
                    'Later',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  _service.retryInstallOrCheckPermission();
                },
                icon: const Icon(Icons.install_mobile_rounded, size: 17),
                label: const Text(
                  'Install Now',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
                style: _primaryButtonStyle(bg: accent),
              ),
            ),
          ],
        );

      case AppUpdatePhase.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _onOpenBrowser(info),
                    icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                    label: const Text(
                      'Browser',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: _secondaryButtonStyle(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      _service.startUpdate(info);
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text(
                      'Try Again',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    style: _primaryButtonStyle(bg: _kAccent),
                  ),
                ),
              ],
            ),
            if (!info.forceUpdate) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => _controller.dismiss(),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Dismiss',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        );

      case AppUpdatePhase.available:
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (!info.forceUpdate) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _controller.collapse();
                      },
                      style: _secondaryButtonStyle(),
                      child: const Text(
                        'Later',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      _service.startUpdate(info);
                    },
                    icon: const Icon(Icons.download_rounded, size: 17),
                    label: const Text(
                      'Update Now',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    style: _primaryButtonStyle(bg: accent),
                  ),
                ),
              ],
            ),
            if (!info.forceUpdate) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => _onSkipVersion(info),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Skip v${info.latestVersion}',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        );
    }
  }

  ButtonStyle _primaryButtonStyle({Color bg = _kAccent}) {
    return ElevatedButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: const Color(0xFF0A0D14),
      elevation: 0,
      shadowColor: Colors.transparent,
      disabledBackgroundColor: bg.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(vertical: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
      ),
    );
  }

  ButtonStyle _secondaryButtonStyle() {
    return OutlinedButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: 0.04),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.13)),
      padding: const EdgeInsets.symmetric(vertical: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
      ),
    );
  }
}
