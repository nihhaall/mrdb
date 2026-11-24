import 'package:amicons/amicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mrdb/home/navs/about.dart';
import 'package:mrdb/home/navs/fav.dart';
import 'package:mrdb/home/navs/first_page/home_page.dart';

// ─── Enums & Providers ────────────────────────────────────────────────────────
enum HomeReleaseCategory { nowReleased, upcoming }

final currentIndexProvider = StateProvider<int>((ref) => 0);

final homeReleaseCategoryProvider = StateProvider<HomeReleaseCategory>(
  (ref) => HomeReleaseCategory.nowReleased,
);

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  final List<Widget> pages = [
    const HomePage(),
    const Favorite(),
    const About(),
  ];

  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kUpcomingAccent = Color(0xFFFF9F1C);
  static const Color _kNavBg = Color(0xFF13161F);

  bool _showHomePopup = false;

  final List<Map<String, dynamic>> _navItems = [
    {
      'label': 'Home',
      'icon': Amicons.iconly_home,
      'activeIcon': Amicons.iconly_home_fill,
    },
    {
      'label': 'Favorites',
      'icon': Amicons.iconly_heart,
      'activeIcon': Amicons.iconly_heart_fill,
    },
    {
      'label': 'About',
      'icon': Amicons.lucide_info,
      'activeIcon': Amicons.lucide_info,
    },
  ];

  @override
  Widget build(BuildContext context) {
    final currentInd = ref.watch(currentIndexProvider);
    final releaseCategory = ref.watch(homeReleaseCategoryProvider);
    final isUpcoming = releaseCategory == HomeReleaseCategory.upcoming;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Pages state kept alive
          IndexedStack(
            index: currentInd,
            children: pages,
          ),

          // 2. Dismiss barrier when Home satellite options are open
          if (_showHomePopup && currentInd == 0)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _showHomePopup = false),
              ),
            ),

          // 3. True Floating Pill & Satellite Menu over the Stack
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Satellite Home Option Bubble (Friendly & Simple!) ──
                    if (_showHomePopup && currentInd == 0) ...[
                      _buildSatellitePopup(releaseCategory),
                      const SizedBox(height: 10),
                    ],

                    // ── Main Floating Nav Bar ──
                    Container(
                      constraints: const BoxConstraints(maxWidth: 310),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _kNavBg.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(32),
                        border: Border.all(
                          color: (currentInd == 0 && isUpcoming
                                  ? _kUpcomingAccent
                                  : _kAccent)
                              .withValues(alpha: 0.4),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (currentInd == 0 && isUpcoming
                                    ? _kUpcomingAccent
                                    : _kAccent)
                                .withValues(alpha: 0.16),
                            blurRadius: 18,
                            spreadRadius: 1,
                            offset: const Offset(0, 2),
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.75),
                            blurRadius: 26,
                            spreadRadius: 2,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(_navItems.length, (index) {
                          final item = _navItems[index];
                          final isSelected = currentInd == index;
                          final isHomeItem = index == 0;

                          // Dynamic styling for Home button based on Released vs Upcoming
                          final Color activeColor =
                              (isHomeItem && isUpcoming)
                                  ? _kUpcomingAccent
                                  : _kAccent;
                          final String activeLabel = isHomeItem
                              ? (isUpcoming ? 'Upcoming' : 'Home')
                              : (item['label'] as String);
                          final IconData activeIcon = isHomeItem
                              ? (isUpcoming
                                  ? Icons.hourglass_top_rounded
                                  : Amicons.iconly_home_fill)
                              : item['activeIcon'];

                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                HapticFeedback.lightImpact();
                                if (currentInd != index) {
                                  setState(() => _showHomePopup = false);
                                  ref.read(currentIndexProvider.notifier).state =
                                      index;
                                } else if (isHomeItem) {
                                  // Tapping Home while already on Home toggles the friendly satellite options!
                                  setState(() {
                                    _showHomePopup = !_showHomePopup;
                                  });
                                }
                              },
                              onLongPress: isHomeItem
                                  ? () {
                                      // Long press quickly flips between Released & Upcoming
                                      HapticFeedback.mediumImpact();
                                      final nextCat = isUpcoming
                                          ? HomeReleaseCategory.nowReleased
                                          : HomeReleaseCategory.upcoming;
                                      ref
                                          .read(
                                            homeReleaseCategoryProvider.notifier,
                                          )
                                          .state = nextCat;
                                      setState(() => _showHomePopup = false);
                                    }
                                  : null,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 240),
                                curve: Curves.easeOutCubic,
                                padding: EdgeInsets.symmetric(
                                  horizontal: isSelected ? 15 : 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? activeColor.withValues(alpha: 0.18)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isSelected
                                        ? activeColor.withValues(alpha: 0.5)
                                        : Colors.transparent,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isSelected ? activeIcon : item['icon'],
                                      color: isSelected
                                          ? activeColor
                                          : Colors.white38,
                                      size: 20,
                                    ),
                                    if (isSelected) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        activeLabel,
                                        style: TextStyle(
                                          color: activeColor,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                      // If on Home, show subtle dropdown cue
                                      if (isHomeItem) ...[
                                        const SizedBox(width: 3),
                                        Icon(
                                          _showHomePopup
                                              ? Icons.keyboard_arrow_down_rounded
                                              : Icons.unfold_more_rounded,
                                          color: activeColor.withValues(
                                            alpha: 0.8,
                                          ),
                                          size: 14,
                                        ),
                                      ],
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
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

  // ── Floating Satellite Bubble anchored right above Home Button ─────────────
  Widget _buildSatellitePopup(HomeReleaseCategory currentCategory) {
    final isReleased = currentCategory == HomeReleaseCategory.nowReleased;
    final isUpcoming = currentCategory == HomeReleaseCategory.upcoming;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF161922).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: (isUpcoming ? _kUpcomingAccent : _kAccent).withValues(
            alpha: 0.45,
          ),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: (isUpcoming ? _kUpcomingAccent : _kAccent).withValues(
              alpha: 0.2,
            ),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Option 1: Now Released
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(homeReleaseCategoryProvider.notifier).state =
                  HomeReleaseCategory.nowReleased;
              setState(() => _showHomePopup = false);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 7.5,
              ),
              decoration: BoxDecoration(
                color: isReleased
                    ? _kAccent.withValues(alpha: 0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isReleased ? _kAccent : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6.5,
                    height: 6.5,
                    decoration: BoxDecoration(
                      color: isReleased ? _kAccent : Colors.white38,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    'Now Released',
                    style: TextStyle(
                      color: isReleased ? _kAccent : Colors.white70,
                      fontSize: 12,
                      fontWeight: isReleased ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 4),

          // Option 2: Upcoming
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(homeReleaseCategoryProvider.notifier).state =
                  HomeReleaseCategory.upcoming;
              setState(() => _showHomePopup = false);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 7.5,
              ),
              decoration: BoxDecoration(
                color: isUpcoming
                    ? _kUpcomingAccent.withValues(alpha: 0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isUpcoming ? _kUpcomingAccent : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.hourglass_top_rounded,
                    size: 13,
                    color: isUpcoming ? _kUpcomingAccent : Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Upcoming',
                    style: TextStyle(
                      color: isUpcoming ? _kUpcomingAccent : Colors.white70,
                      fontSize: 12,
                      fontWeight: isUpcoming ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: _kUpcomingAccent.withValues(
                        alpha: isUpcoming ? 0.3 : 0.15,
                      ),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Text(
                      'SOON',
                      style: TextStyle(
                        color: _kUpcomingAccent,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
