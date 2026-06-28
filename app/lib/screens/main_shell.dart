import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/crosslink_theme.dart';
import 'discover_screen.dart';
import 'home_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final _homeKey = GlobalKey<HomeScreenState>();
  final _sessionsKey = GlobalKey<SessionsScreenState>();
  final _discoverKey = GlobalKey<DiscoverScreenState>();

  static const _tabs = <_TabDef>[
    _TabDef(label: '设备', icon: Icons.devices_outlined, activeIcon: Icons.devices),
    _TabDef(label: '会话', icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble),
    _TabDef(label: '能力', icon: Icons.toggle_on_outlined, activeIcon: Icons.toggle_on),
    _TabDef(label: '设置', icon: Icons.settings_outlined, activeIcon: Icons.settings),
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
        _discoverKey.currentState?.refresh();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedSwitcher(
        duration: CrossLinkTheme.normal,
        switchInCurve: CrossLinkTheme.curve,
        switchOutCurve: CrossLinkTheme.curve,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.98, end: 1.0).animate(animation),
              child: child,
            ),
          );
        },
        child: _buildPage(_currentIndex),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: CrossLinkTheme.surface.withAlpha(240),
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabSelected,
        animationDuration: CrossLinkTheme.normal,
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

  Widget _buildPage(int index) {
    switch (index) {
      case 0:
        return HomeScreen(key: _homeKey);
      case 1:
        return SessionsScreen(key: _sessionsKey);
      case 2:
        return DiscoverScreen(key: _discoverKey);
      default:
        return const SettingsScreen();
    }
  }
}

class _TabDef {
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const _TabDef({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}
