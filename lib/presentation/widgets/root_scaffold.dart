import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../history/history_screen.dart';
import '../home/home_screen.dart';
import '../learn/learn_screen.dart';
import '../live/live_screen.dart';
import '../providers/providers.dart';

/// Hosts the tabs behind a single persistent [NavigationBar]: Learn (0) -> Home
/// (1) -> Live (2) -> History (3), Home selected on launch. [IndexedStack] keeps
/// the Live screen's plugin and accumulated sentence alive across tab switches;
/// its camera is still acquired and released on activation.
class RootScaffold extends ConsumerWidget {
  const RootScaffold({super.key});

  // Order must match AppConstants.*TabIndex -- LiveScreen gates camera
  // acquisition on its index, so the two cannot drift apart.
  static const _screens = [
    LearnScreen(),
    HomeScreen(),
    LiveScreen(),
    HistoryScreen(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIndex = ref.watch(bottomNavIndexProvider);

    return Scaffold(
      body: IndexedStack(
        index: selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) =>
        ref.read(bottomNavIndexProvider.notifier).state = index,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school_rounded),
            label: 'Learn',
          ),
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.back_hand_outlined),
            selectedIcon: Icon(Icons.back_hand_rounded),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: 'History',
          ),
        ],
      ),
    );
  }
}