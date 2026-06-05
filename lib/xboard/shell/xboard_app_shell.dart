/// 形态 A 自定义三 Tab 外壳（spec `xboard-form-a-ui-revamp` / design P1 接缝点 #9）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 形态 A 三 Tab 外壳（首页 / 节点 / 我的）。
class XboardAppShell extends ConsumerStatefulWidget {
  const XboardAppShell({super.key});

  @override
  ConsumerState<XboardAppShell> createState() => _XboardAppShellState();
}

class _XboardAppShellState extends ConsumerState<XboardAppShell> {
  int _tabIndex = 0;

  void _onTabSelected(int index) => setState(() => _tabIndex = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _tabIndex,
          children: const [
            _HomeTabStub(),
            _NodesTabStub(),
            _MineTabStub(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: _onTabSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: '节点',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

class _HomeTabStub extends StatelessWidget {
  const _HomeTabStub();

  @override
  Widget build(BuildContext context) =>
      const _TabPlaceholder(icon: Icons.home, label: '首页');
}

class _NodesTabStub extends StatelessWidget {
  const _NodesTabStub();

  @override
  Widget build(BuildContext context) =>
      const _TabPlaceholder(icon: Icons.public, label: '节点');
}

class _MineTabStub extends StatelessWidget {
  const _MineTabStub();

  @override
  Widget build(BuildContext context) =>
      const _TabPlaceholder(icon: Icons.person, label: '我的');
}

class _TabPlaceholder extends StatelessWidget {
  const _TabPlaceholder({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: scheme.primary),
          const SizedBox(height: 12),
          Text(label, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
