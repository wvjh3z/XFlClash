/// XbIconBadge 结构契约测试（批次三：视觉基元收敛，断言透传参数原样落到容器/图标）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';

Future<Container> _container(WidgetTester t) async {
  return t.widget<Container>(
    find.descendant(
      of: find.byType(XbIconBadge),
      matching: find.byType(Container),
    ),
  );
}

void main() {
  testWidgets('纯色背景：尺寸/圆角/底色/图标色原样透传', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: XbIconBadge(
          icon: Icons.settings,
          size: 40,
          radius: 12,
          background: Color(0xFFEEEEEE),
          iconColor: Color(0xFF112233),
          iconSize: 20,
        ),
      ),
    ));
    final c = await _container(t);
    expect(c.constraints?.maxWidth, 40);
    expect(c.constraints?.maxHeight, 40);
    final deco = c.decoration as BoxDecoration;
    expect(deco.color, const Color(0xFFEEEEEE));
    expect(deco.gradient, isNull);
    expect(deco.borderRadius, BorderRadius.circular(12));
    final icon = t.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.settings);
    expect(icon.size, 20);
    expect(icon.color, const Color(0xFF112233));
  });

  testWidgets('渐变背景：gradient 落到 decoration，color 为 null', (t) async {
    const grad = LinearGradient(colors: [Color(0xFFFF0000), Color(0xFF990000)]);
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: XbIconBadge(icon: Icons.person, gradient: grad),
      ),
    ));
    final c = await _container(t);
    final deco = c.decoration as BoxDecoration;
    expect(deco.gradient, grad);
    expect(deco.color, isNull, reason: '渐变时纯色背景应为 null');
  });

  testWidgets('默认图标尺寸 = size 的一半', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: XbIconBadge(icon: Icons.star, size: 48)),
    ));
    final icon = t.widget<Icon>(find.byType(Icon));
    expect(icon.size, 24);
  });

  test('background 与 gradient 互斥（assert）', () {
    expect(
      () => XbIconBadge(
        icon: Icons.bug_report,
        background: const Color(0xFF000000),
        gradient: const LinearGradient(colors: [Colors.red, Colors.blue]),
      ),
      throwsAssertionError,
    );
  });
}
