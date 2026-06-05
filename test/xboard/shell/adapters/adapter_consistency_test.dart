/// W6.3 — adapter 复用一致性 + 降级单测（Property 4 / 风险②b / NFR-2.2）。
///
/// **Property 4「无影子状态」**：adapter 不自持脱节状态——读路径直接投影 FlClash provider，
/// provider 真值变 → adapter 读出即变（无中间缓存）。本测验「改 FlClash 真值 → adapter 读回
/// 一致」。注：`setMode`/`toggle` 的**写穿**会触达 core/DB（path_provider headless 不可用），
/// 由 W6.4 集成冒烟在真机/模拟器验证；此处验「无影子状态」的读一致性（单元级可证部分）。
///
/// **降级**：trafficsProvider 空 → `currentTraffic` 返 0/0 不崩（fallback）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/common/common.dart' show FixedList;
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show Traffic;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_mode_adapter.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_traffic_adapter.dart';

/// Probe：在 widget 树里持 WidgetRef，供 adapter 读操作调用。
class _Probe extends ConsumerWidget {
  const _Probe(this.onRef);
  final void Function(WidgetRef) onRef;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox.shrink();
  }
}

void main() {
  testWidgets('Property 4：FlClash mode 真值变 → adapter 读回一致（无影子状态）',
      (tester) async {
    late WidgetRef capturedRef;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: _Probe((ref) => capturedRef = ref)),
      ),
    );

    const adapter = XbModeAdapter();
    // 默认 rule → smart。
    expect(adapter.currentMode(capturedRef), XbMode.smart);

    // 直接改 FlClash 真值（模拟内核侧 / 其它入口改 mode）。
    container
        .read(patchClashConfigProvider.notifier)
        .update((s) => s.copyWith(mode: Mode.global));
    await tester.pump();
    // adapter 读出即变（无中间缓存）。
    expect(adapter.currentMode(capturedRef), XbMode.global);

    // direct（formA 无法表达）→ 归一为 smart。
    container
        .read(patchClashConfigProvider.notifier)
        .update((s) => s.copyWith(mode: Mode.direct));
    await tester.pump();
    expect(adapter.currentMode(capturedRef), XbMode.smart);
  });

  test('Property 4：XbModeAdapter 无实例字段（结构性无影子状态）', () {
    // const 构造 + 无字段：adapter 不可能持有脱节状态。
    const a = XbModeAdapter();
    const b = XbModeAdapter();
    expect(identical(a, b), isTrue, reason: 'const 单态，无实例状态');
  });

  testWidgets('降级：trafficsProvider 空 → currentTraffic 返 0/0 不崩', (tester) async {
    late WidgetRef capturedRef;
    final container = ProviderContainer(
      overrides: [
        trafficsProvider.overrideWithBuild((ref, _) => FixedList<Traffic>(10)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: _Probe((ref) => capturedRef = ref)),
      ),
    );
    const adapter = XbTrafficAdapter();
    final t = adapter.currentTraffic(capturedRef);
    expect(t.up, 0);
    expect(t.down, 0);
  });

  testWidgets('降级：trafficsProvider 有值 → 取最新帧（一致性）', (tester) async {
    late WidgetRef capturedRef;
    final container = ProviderContainer(
      overrides: [
        trafficsProvider.overrideWithBuild(
          (ref, _) => FixedList<Traffic>(10, list: const [
            Traffic(up: 1, down: 2),
            Traffic(up: 7, down: 9),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: _Probe((ref) => capturedRef = ref)),
      ),
    );
    const adapter = XbTrafficAdapter();
    final t = adapter.currentTraffic(capturedRef);
    expect(t.up, 7);
    expect(t.down, 9);
  });
}
