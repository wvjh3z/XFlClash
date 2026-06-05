/// W2.1 — XbConnectAdapter 4 态合成单测。
///
/// 覆盖（design 风险②「连接中态」坑）：
/// - !bootstrapReady → booting（canToggle=false）
/// - coreStatus==connecting → connecting
/// - isStart（runTime!=null）→ connected
/// - 否则 → disconnected
///
/// 驱动方式：`bootstrapReadyProvider` / `coreStatusProvider` 是 Notifier（mount 后经
/// `.notifier.value` 写）；`isStartProvider` 是 functional provider（`overrideWith` 注值）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_connect_adapter.dart';

class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const adapter = XbConnectAdapter();
    final state = adapter.connState(ref);
    final canToggle = adapter.canToggle(ref);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text('${state.name}|$canToggle'),
    );
  }
}

void main() {
  String readLabel(WidgetTester tester) =>
      tester.widget<Text>(find.byType(Text)).data!;

  testWidgets('!bootstrapReady → booting（canToggle=false）', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        // 默认 bootstrapReady=false（build 返回 false），无需 override。
        child: _Probe(),
      ),
    );
    expect(readLabel(tester), 'booting|false');
  });

  testWidgets('ready + coreStatus==connecting → connecting', (tester) async {
    final container = ProviderContainer(
      overrides: [isStartProvider.overrideWith((ref) => false)],
    );
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _Probe()),
    );
    expect(readLabel(tester), 'connecting|true');
  });

  testWidgets('ready + 非 connecting + isStart=false → disconnected',
      (tester) async {
    final container = ProviderContainer(
      overrides: [isStartProvider.overrideWith((ref) => false)],
    );
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _Probe()),
    );
    expect(readLabel(tester), 'disconnected|true');
  });

  testWidgets('ready + 非 connecting + isStart=true → connected', (tester) async {
    final container = ProviderContainer(
      overrides: [isStartProvider.overrideWith((ref) => true)],
    );
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _Probe()),
    );
    expect(readLabel(tester), 'connected|true');
  });
}
