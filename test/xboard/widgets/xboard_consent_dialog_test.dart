/// W4.2 — XboardConsentDialog GDPR（3 段文案 + 同意/拒绝持久化 + schema v1）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/widgets/xboard_consent_dialog.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpAndTrigger(WidgetTester t, {required void Function(bool) onResult}) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              final r = await XboardConsentDialog.ensureConsent(context);
              onResult(r);
            },
            child: const Text('go'),
          );
        }),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
  }

  testWidgets('首次：弹窗 3 段文案 + 链接 + 双按钮', (t) async {
    await pumpAndTrigger(t, onResult: (_) {});
    expect(find.text('数据与隐私告知'), findsOneWidget);
    expect(find.text('我们会收集'), findsOneWidget);
    expect(find.text('数据存储与跨境'), findsOneWidget);
    expect(find.text('第三方 SDK'), findsOneWidget);
    expect(find.text('用户协议'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('同意并继续'), findsOneWidget);
    expect(find.text('暂不'), findsOneWidget);
  });

  testWidgets('同意 → 写 xb_consent_v1=true + 返 true', (t) async {
    bool? result;
    await pumpAndTrigger(t, onResult: (r) => result = r);
    await t.tap(find.text('同意并继续'));
    await t.pumpAndSettle();
    expect(result, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('xb_consent_v1'), isTrue);
  });

  testWidgets('拒绝 → 不写值 + 返 false', (t) async {
    bool? result;
    await pumpAndTrigger(t, onResult: (r) => result = r);
    await t.tap(find.text('暂不'));
    await t.pumpAndSettle();
    expect(result, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('xb_consent_v1'), isNull); // 未写
  });

  testWidgets('已同意 → 不再弹窗，直接 true', (t) async {
    SharedPreferences.setMockInitialValues({'xb_consent_v1': true});
    bool? result;
    await pumpAndTrigger(t, onResult: (r) => result = r);
    expect(find.text('数据与隐私告知'), findsNothing); // 不弹
    expect(result, isTrue);
  });
}
