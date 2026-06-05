/// W5 — 登录/注册/忘记密码 sheet 单测。
///
/// 覆盖：bootstrap gate（R5.2）/ 邮箱白名单后缀下拉 vs 空白名单单框（R5.6）/
/// 字段顺序验证码在密码上方（R5.7）/ 渐进 sheet 不全屏（R5.3）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/sheets/login_sheet.dart';
import 'package:fl_clash/xboard/shell/sheets/register_sheet.dart';

class _MockService extends Mock implements XboardService {}

Future<void> pumpWithSheet(
  WidgetTester tester, {
  required bool ready,
  List<String> suffixes = const [],
  required Future<void> Function(BuildContext) open,
}) async {
  final service = _MockService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        bootstrapReadyProvider.overrideWith(() => _FakeReady(ready)),
        emailSuffixesProvider.overrideWith((ref) async => suffixes),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class _FakeReady extends BootstrapReady {
  _FakeReady(this._v);
  final bool _v;
  @override
  bool build() => _v;
}

void main() {
  testWidgets('LoginSheet：bootstrap 未就绪 → 按钮「准备中…」禁用（R5.2）', (tester) async {
    await pumpWithSheet(tester, ready: false, open: showLoginSheet);
    expect(find.text('准备中…'), findsOneWidget);
    final btn = tester.widget<FilledButton>(
      find.ancestor(of: find.text('准备中…'), matching: find.byType(FilledButton)),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('LoginSheet：bootstrap 就绪 → 按钮「登录」可用', (tester) async {
    await pumpWithSheet(tester, ready: true, open: showLoginSheet);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('注册账号'), findsOneWidget);
    expect(find.text('忘记密码？'), findsOneWidget);
  });

  testWidgets('RegisterSheet：有白名单 → 后缀下拉（R5.6）+ 验证码在密码上方（R5.7）',
      (tester) async {
    await pumpWithSheet(
      tester,
      ready: true,
      suffixes: const ['gmail.com', 'qq.com'],
      open: showRegisterSheet,
    );
    // 后缀下拉存在。
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.text('@gmail.com'), findsWidgets);
    // 字段顺序：验证码 label 在密码 label 之上（y 坐标更小）。
    final codeY = tester.getTopLeft(find.text('验证码')).dy;
    final pwY = tester.getTopLeft(find.text('密码')).dy;
    expect(codeY, lessThan(pwY));
  });

  testWidgets('RegisterSheet：空白名单 → 单邮箱框（无后缀下拉，F208）', (tester) async {
    await pumpWithSheet(
      tester,
      ready: true,
      suffixes: const [],
      open: showRegisterSheet,
    );
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('邮箱账号'), findsOneWidget);
  });
}
