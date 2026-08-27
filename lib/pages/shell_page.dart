import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';

final shellTabProvider =
    NotifierProvider<ShellTabNotifier, int>(ShellTabNotifier.new);

class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void select(int index) => state = index;
}

/// Bottom navigation shell with 3 tabs: Home, History, Settings.
class ShellPage extends ConsumerWidget {
  const ShellPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(shellTabProvider);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const [HomePage(), HistoryPage(), SettingsPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(shellTabProvider.notifier).select(i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
