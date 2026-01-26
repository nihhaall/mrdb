import 'dart:ui';
import 'package:amicons/amicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mrdb/home/navs/about.dart';
import 'package:mrdb/home/navs/fav.dart';
import 'package:mrdb/home/navs/first_page/home_page.dart';
import 'package:mrdb/main.dart';

final currentIndexProvider = StateProvider<int>((ref) => 0);

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

  final List<BottomNavigationBarItem> navs = [
    const BottomNavigationBarItem(
      icon: Icon(Amicons.iconly_home),
      label: 'Home',
    ),
    const BottomNavigationBarItem(
      icon: Icon(Amicons.iconly_heart),
      label: 'Favorites',
    ),
    const BottomNavigationBarItem(
      icon: Icon(Amicons.lucide_info),
      label: 'About',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final currentInd = ref.watch(currentIndexProvider);

    return Scaffold(
      body: pages[currentInd],
      bottomNavigationBar: BottomNavigationBar(
        items: navs,
        currentIndex: currentInd,
        backgroundColor: Colors.black,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.grey,
        elevation: 0,
        selectedFontSize: wt*0.035,
        unselectedFontSize: wt*0.025,
        type: BottomNavigationBarType.fixed,

        selectedIconTheme: IconThemeData(size: wt*0.07),
        unselectedIconTheme: IconThemeData(size: wt*0.04),
        onTap: (index) {
          ref.read(currentIndexProvider.notifier).state = index;
        },
      ),
    );
  }
}
