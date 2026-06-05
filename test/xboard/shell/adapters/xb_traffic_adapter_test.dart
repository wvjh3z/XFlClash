/// W2.2 — XbTrafficAdapter 单测（读 trafficsProvider 最新一帧）。
///
/// 注意：`Traffics.build()` 默认 `FixedList(0)`（maxLength 0，add 即被截断）；真实 app 经
/// `overrideWithBuild` 注入有容量的 list。测试同样用 `overrideWithBuild` 注入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/common/common.dart' show FixedList;
import 'package:fl_clash/models/models.dart' show Traffic;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_traffic_adapter.dart';

class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const adapter = XbTrafficAdapter();
    final t = adapter.currentTraffic(ref);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text('${t.up}|${t.down}'),
    );
  }
}

void main() {
  testWidgets('空列表 → 0|0', (tester) async {
    final container = ProviderContainer(
      overrides: [
        trafficsProvider.overrideWithBuild((ref, _) => FixedList<Traffic>(10)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _Probe()),
    );
    expect(tester.widget<Text>(find.byType(Text)).data, '0|0');
  });

  testWidgets('有数据 → 取最新一帧 up|down', (tester) async {
    final container = ProviderContainer(
      overrides: [
        trafficsProvider.overrideWithBuild(
          (ref, _) => FixedList<Traffic>(10, list: [
            const Traffic(up: 10, down: 20),
            const Traffic(up: 111, down: 222),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _Probe()),
    );
    // 取最新一帧（list.last）。
    expect(tester.widget<Text>(find.byType(Text)).data, '111|222');
  });
}

