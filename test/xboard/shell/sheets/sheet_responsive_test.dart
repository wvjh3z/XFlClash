import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/sheets/sheet_scaffold.dart';

void main() {
  for (final width in [599.0, 600.0]) {
    testWidgets('认证弹窗在$width宽度选择正确路由且键盘下可滚动', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.4),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(builder: (context) => TextButton(
            onPressed: () => showXbBottomSheet<void>(
              context: context,
              builder: (_) => const XbSheetScaffold(
                title: '用于验证键盘和长内容的认证表单',
                children: [
                  TextField(key: ValueKey('email'), decoration: InputDecoration(labelText: '邮箱')),
                  SizedBox(height: 420),
                  Text('表单末尾'),
                ],
              ),
            ),
            child: const Text('打开认证弹窗'),
          )),
        ),
      ));
      await tester.tap(find.text('打开认证弹窗'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), width >= 600 ? findsOneWidget : findsNothing);
      expect(find.byType(BottomSheet), width < 600 ? findsOneWidget : findsNothing);
      await tester.tap(find.byKey(const ValueKey('email')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('表单末尾'));
      await tester.pump();
      final footer = tester.getRect(find.text('表单末尾'));
      expect(footer.top, greaterThanOrEqualTo(0));
      expect(footer.bottom, lessThanOrEqualTo(540));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(XbSheetScaffold), findsNothing);
    });
  }
}
