/// W2.3 — XbModeAdapter 三态映射 + direct 归一单测。
///
/// 读路径只触 `patchClashConfigProvider`；映射：rule→smart / global→global / direct→smart。
/// 用 `overrideWithBuild` 在 provider 层注入初始 mode（避免 build 期改 provider / pending timer）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show PatchClashConfig;
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_mode_adapter.dart';

class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const adapter = XbModeAdapter();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(adapter.currentMode(ref).name),
    );
  }
}

void main() {
  Future<XbMode> readMode(WidgetTester tester, Mode flMode) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          patchClashConfigProvider
              .overrideWithBuild((ref, _) => PatchClashConfig(mode: flMode)),
        ],
        child: const _Probe(),
      ),
    );
    final name = tester.widget<Text>(find.byType(Text)).data!;
    return XbMode.values.firstWhere((m) => m.name == name);
  }

  testWidgets('Mode.rule → smart', (tester) async {
    expect(await readMode(tester, Mode.rule), XbMode.smart);
  });

  testWidgets('Mode.global → global', (tester) async {
    expect(await readMode(tester, Mode.global), XbMode.global);
  });

  testWidgets('Mode.direct → smart（归一，formA 无 direct）', (tester) async {
    expect(await readMode(tester, Mode.direct), XbMode.smart);
  });
}
