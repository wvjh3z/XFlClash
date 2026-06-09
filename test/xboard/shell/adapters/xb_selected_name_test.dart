/// XbNodesAdapter.selectedName 乐观选中（修「computed 组选中态不立即更新」bug）。
///
/// url-test/fallback（computed）组：用户**显式锁定**节点（写入 selectedMap）后，selectedName
/// 应立即返回该节点——不等 core 运行值 now 更新（否则 UI 高亮延迟到测速完成）。
/// selector 组本就立即认 selectedMap，回归保证不变。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show Group, Proxy;
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider;
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';

const _hk = '🇭🇰 香港1';
const _jp = '🇯🇵 日本1';

/// 读 selectedName（接收 WidgetRef，用 Consumer 桥接）。
Future<String?> sel(
  WidgetTester t, {
  required List<Group> groups,
  required Map<String, String> selectedMap,
  required String groupName,
}) async {
  late String? out;
  await t.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: [
      groupsProvider.overrideWithValue(groups),
      selectedMapProvider.overrideWith((ref) => selectedMap),
    ],
    child: MaterialApp(
      home: Consumer(builder: (ctx, ref, _) {
        out = const XbNodesAdapter().selectedName(ref, groupName);
        return const SizedBox();
      }),
    ),
  ));
  await t.pump();
  return out;
}

Group _urlTest({String? now}) => Group(
      type: GroupType.URLTest,
      name: '自动选择',
      now: now,
      all: const [
        Proxy(name: _hk, type: 'ss'),
        Proxy(name: _jp, type: 'ss'),
      ],
    );

Group _selector({String? now}) => Group(
      type: GroupType.Selector,
      name: '手动选择',
      now: now,
      all: const [
        Proxy(name: _hk, type: 'ss'),
        Proxy(name: _jp, type: 'ss'),
      ],
    );

void main() {
  testWidgets('computed 组：用户锁定日本（now 还是香港）→ 立即返回日本（乐观）', (t) async {
    // core now 仍是旧的香港（切换+测速未回），但用户已显式锁定日本。
    final r = await sel(t,
        groups: [_urlTest(now: _hk)],
        selectedMap: {'自动选择': _jp},
        groupName: '自动选择');
    expect(r, _jp, reason: 'computed 组显式锁定应立即生效，不等 core now');
  });

  testWidgets('computed 组：未锁定（selectedMap 空）→ 回退 core now（跟随自动）', (t) async {
    final r = await sel(t,
        groups: [_urlTest(now: _hk)],
        selectedMap: const {},
        groupName: '自动选择');
    expect(r, _hk, reason: '未锁定时跟随 core 自动命中的 now');
  });

  testWidgets('selector 组：锁定日本 → 立即返回日本（行为不变）', (t) async {
    final r = await sel(t,
        groups: [_selector(now: _hk)],
        selectedMap: {'手动选择': _jp},
        groupName: '手动选择');
    expect(r, _jp);
  });
}
