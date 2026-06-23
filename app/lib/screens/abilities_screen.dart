import 'package:flutter/material.dart';
import '../theme/crosslink_theme.dart';
import 'agents_screen.dart';
import 'models_screen.dart';

class AbilitiesScreen extends StatefulWidget {
  const AbilitiesScreen({super.key});
  @override
  State<AbilitiesScreen> createState() => _AbilitiesScreenState();
}

class _AbilitiesScreenState extends State<AbilitiesScreen>
    with TickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('能力'),
        backgroundColor: CrossLinkTheme.deepSpaceElevated,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: CrossLinkTheme.accent,
          labelColor: CrossLinkTheme.accent,
          unselectedLabelColor: CrossLinkTheme.textMuted,
          tabs: const [
            Tab(icon: Icon(Icons.memory), text: '模型'),
            Tab(icon: Icon(Icons.dns), text: 'Agent'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          ModelsScreen(),
          AgentsScreen(),
        ],
      ),
    );
  }
}
