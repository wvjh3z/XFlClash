/// Login 页 golden 快照 —— 生成真实渲染 PNG（软件渲染，无需 Ninja/Rust）。
///
/// 生成/更新：flutter test --update-goldens test/xboard/golden/login_page_golden_test.dart
/// 产物：test/xboard/golden/goldens/login_*.png（用编辑器打开看真实效果）。
///
/// 注：默认 flutter test 用占位字体（中文/英文可能渲染成方块），但布局 / 配色 / 组件形状 /
/// 间距 / 圆角 / 投影 全部是真实渲染，足以判断视觉结构与品牌色效果。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/pages/login_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  testWidgets('login light（移动尺寸）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(_MockService()),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
          home: const XboardLoginPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(XboardLoginPage),
      matchesGoldenFile('goldens/login_light_mobile.png'),
    );
  });

  testWidgets('login dark（移动尺寸）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(_MockService()),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: const XboardLoginPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(XboardLoginPage),
      matchesGoldenFile('goldens/login_dark_mobile.png'),
    );
  });
}
