import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'sessions_screen.dart';
import 'abilities_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final _homeKey = GlobalKey<HomeScreenState>();
  final _sessionsKey = GlobalKey<SessionsScreenState>();
  final _abilitiesKey = GlobalKey<AbilitiesScreenState>();

  static const _tabs = <_TabDef>[
    _TabDef(label: '信使', icon: Icons.auto_awesome, activeIcon: Icons.auto_awesome),
    _TabDef(label: '会话', icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble),
    _TabDef(label: '能力', icon: Icons.grid_view_outlined, activeIcon: Icons.grid_view),
    _TabDef(label: '我的', icon: Icons.person_outline, activeIcon: Icons.person),
  ];

  void _onTabSelected(int index) {
    if (index == _currentIndex) return;
    HapticFeedback.lightImpact();
    setState(() => _currentIndex = index);
    switch (index) {
      case 0:
        _homeKey.currentState?.refresh();
        break;
      case 1:
        _sessionsKey.currentState?.refresh();
        break;
      case 2:
        _abilitiesKey.currentState?.refresh();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(key: _homeKey),
          SessionsScreen(key: _sessionsKey),
          AbilitiesScreen(key: _abilitiesKey),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabSelected,
        animationDuration: const Duration(milliseconds: 300),
        destinations: _tabs
            .map((t) => NavigationDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.activeIcon),
                  label: t.label,
                ))
            .toList(),
      ),
    );
  }
}

class _TabDef {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  const _TabDef({required this.label, required this.icon, required this.activeIcon});
}
