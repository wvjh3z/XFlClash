import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_center_toast.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';

void main() {
  testWidgets('replacement and owner dismissal never remove a newer toast', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    final first = XbCenterToast.show(context, '原提示');
    await tester.pump();
    final second = XbCenterToast.show(
      context,
      '正在刷新套餐与节点信息。',
      title: '支付成功',
      tone: XbToastTone.success,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    first?.call();
    await tester.pump();
    expect(find.text('原提示'), findsNothing);
    expect(find.text('支付成功'), findsOneWidget);
    second?.call();
    second?.call();
    await tester.pump();
    expect(find.text('支付成功'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('default appearance stays amber and duration removes its timer', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    XbCenterToast.show(context, '默认提示', duration: const Duration(seconds: 1));
    await tester.pump();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.info_outline_rounded)).color,
      XbTokens.warn,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('默认提示'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dark error feedback wraps long copy at large text scale', (
    tester,
  ) async {
    late BuildContext context;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXbTheme(
          brandColor: Colors.red,
          brightness: Brightness.dark,
        ),
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(
            ctx,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    final dismiss = XbCenterToast.show(
      context,
      '暂未获取到最新状态，请稍后重新检测。',
      title: '检测失败',
      tone: XbToastTone.error,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final color = tester.widget<Text>(find.text('检测失败')).style!.color!;
    expect(
      color.computeLuminance(),
      greaterThan(XbTokens.bad.computeLuminance()),
    );
    expect(tester.takeException(), isNull);
    dismiss?.call();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
