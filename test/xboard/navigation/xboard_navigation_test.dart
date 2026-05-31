/// W1.3.6 + W1.4.3 — XboardNavigation + XboardServiceHomePage stub widget test。
///
/// 验证：
/// - XboardNavigation.items 含 1 项「我的服务」（mobile + desktop）
/// - 接缝点 #6 后 navigation.getItems() 含 9 项（FlClash 8 + Xboard 1）
/// - isXboardItem 判别 + titleOf 自渲染标题
/// - XboardServiceHomePage stub 渲染「我的服务」文本

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/common/navigation.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/xboard/navigation/xboard_navigation.dart';
import 'package:fl_clash/xboard/pages/xboard_service_home_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  group('XboardNavigation', () {
    test('items 含 1 项（mobile + desktop 双形态）', () {
      expect(XboardNavigation.items, hasLength(1));
      final item = XboardNavigation.items.first;
      expect(item.modes, containsAll([
        NavigationItemMode.mobile,
        NavigationItemMode.desktop,
      ]));
    });

    test('isXboardItem 判别 Xboard 项 vs FlClash 项', () {
      final all = navigation.getItems();
      final xboardItems = all.where(XboardNavigation.isXboardItem).toList();
      expect(xboardItems, hasLength(1));
      // FlClash 原生项不被误判
      final flclashItems = all.where((i) => !XboardNavigation.isXboardItem(i));
      expect(flclashItems.length, greaterThanOrEqualTo(8));
    });

    test('titleOf 自渲染中文标题（决策 #8(b) / D15）', () {
      expect(XboardNavigation.titleOf(XboardNavigation.items.first), '我的服务');
    });
  });

  group('接缝点 #6：navigation.getItems()', () {
    test('注入后含 9 项（FlClash 8 + Xboard 1）', () {
      // openLogs + hasProxies 全开，FlClash 项最大化（8 项），+ Xboard 1 = 9
      final items = navigation.getItems(openLogs: true, hasProxies: true);
      expect(items, hasLength(9));
      // 最后一项是 Xboard 注入项
      expect(XboardNavigation.isXboardItem(items.last), isTrue);
    });
  });

  group('XboardServiceHomePage stub（W1.4）', () {
    testWidgets('渲染「我的服务」文本', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: XboardServiceHomePage()),
        ),
      );
      expect(find.text('我的服务'), findsOneWidget);
    });
  });
}
