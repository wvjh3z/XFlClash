/// R4.8 — ManualConfigImportPage widget test：渲染 + 空导入提示 + 成功流。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/pages/manual_config_import_page.dart';

import '../services/_bootstrap_crypto_helper.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 绑定带已知 AES key 的 config（manual import 页用 XboardConfig.current.aesKey）。
    XboardConfig.bind(XboardConfig(
      subscribeUserAgent: 'Test/0.1 flclash',
      devApiEndpoint: 'https://factory.example.com',
      devSubscriptionEndpoint: 'https://factory-sub.example.com',
      debug: false,
      kIsTest: true,
      bootstrapAesKeyBytes: testAesKey,
    ));
  });
  tearDown(XboardConfig.resetForTest);

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ManualConfigImportPage()),
    ));
  }

  testWidgets('渲染：标题 + 输入框 + 导入按钮', (t) async {
    await pump(t);
    expect(find.text('手动导入配置'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '导入配置'), findsOneWidget);
  });

  testWidgets('空输入点导入 → 错误提示', (t) async {
    await pump(t);
    await t.tap(find.widgetWithText(FilledButton, '导入配置'));
    await t.pump();
    expect(find.textContaining('请先粘贴'), findsOneWidget);
  });

  testWidgets('粘贴合法密文 → 导入成功视图', (t) async {
    final enc = await encryptPayload({
      'schema_version': 2,
      'api_endpoints': [
        {'url': 'https://api.com', 'region': 'overseas'}
      ],
      'subscription_endpoints': [
        {'url': 'https://sub.com', 'region': 'cn'}
      ],
    });
    final text = jsonEncode({'schema_version': 2, 'encrypted': enc});

    await pump(t);
    await t.enterText(find.byType(TextField), text);
    await t.tap(find.widgetWithText(FilledButton, '导入配置'));
    await t.pump(); // busy
    await t.pumpAndSettle(); // await import + 重建成功视图
    expect(find.text('配置导入成功'), findsOneWidget);
    expect(find.textContaining('1 个接口线路'), findsOneWidget);
  });

  testWidgets('粘贴非法内容 → 错误提示（格式不正确）', (t) async {
    await pump(t);
    await t.enterText(find.byType(TextField), '不是 JSON 的乱码');
    await t.tap(find.widgetWithText(FilledButton, '导入配置'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('格式不正确'), findsOneWidget);
  });
}
