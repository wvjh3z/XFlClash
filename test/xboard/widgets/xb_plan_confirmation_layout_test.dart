import 'package:fl_clash/xboard/widgets/xb_purchase_confirmation.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('plan switch uses available space at $width', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 800);
      addTearDown(t.view.reset);
      const target = '多国家特别版（轻量）';
      const note = '更换会覆盖现有套餐，剩余流量和有效期不会保留。';
      await t.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => TextButton(
        onPressed: () => showDialog<void>(context: ctx, builder: (_) => const XbPlanConfirmation(
          planName: 'SVIP', targetName: target, confirmLabel: '确认更换')),
        child: const Text('打开')))));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      for (final value in [target,note]) {
        final paragraph = t.renderObject<RenderParagraph>(find.text(value,findRichText:true));
        final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset:0,extentOffset:value.length));
        expect(boxes,isNotEmpty);
        if (width >= 600) expect(boxes.map((b) => b.bottom).toSet(),hasLength(1));
      }
      expect(find.text('确认更换').hitTestable(), findsOneWidget);
      expect(t.takeException(),isNull);
    });
  }
}
