import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/pending_order_section.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
class _Service extends Mock implements XboardService {}
void main() {
 for(final brand in ['brand_a','brand_b']) {
  for(final platform in [TargetPlatform.android,TargetPlatform.windows,TargetPlatform.macOS,TargetPlatform.linux]) {
   for(final mode in ['normal','disposed','session','service','late-dispose','late-session','dismiss']) {
    testWidgets('$brand $platform pending confirmation $mode',(tester) async {
      tester.view.physicalSize=const Size(1000,1000);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.reset);
      XboardConfig.bind(XboardConfig(appName:brand,flavorId:brand,subscribeUserAgent:'fixture',devApiEndpoint:'',devSubscriptionEndpoint:'',debug:true,kIsTest:true,formA:true));
      addTearDown(XboardConfig.resetForTest);
      final a=_Service();final b=_Service();XboardService current=a;
      final response=Completer<XbResult<bool>>();
      when(()=>a.cancelOrder(any())).thenAnswer((_)=>response.future);
      when(()=>b.cancelOrder(any())).thenAnswer((_)async=>const XbSuccess(true));
      final visible=ValueNotifier(true);addTearDown(visible.dispose);
      final order=OrderSummary(tradeNo:'fixture',planName:'fixture',period:XbPlanPeriod.monthly,totalAmountYuan:1,status:XbOrderStatus.pending,createdAt:DateTime(2026));
      await tester.pumpWidget(ProviderScope(overrides:[xboardServiceProvider.overrideWith((ref)=>current),pendingOrderProvider.overrideWith((ref)async=>order)],
       child:MaterialApp(theme:ThemeData(platform:platform),home:Scaffold(body:ValueListenableBuilder<bool>(valueListenable:visible,builder:(context,value,_)=>value?const PendingOrderSection():const SizedBox())))));
      await tester.pumpAndSettle();
      final container=ProviderScope.containerOf(tester.element(find.byType(PendingOrderSection)));
      await tester.tap(find.text('取消订单'));await tester.pumpAndSettle();
      if(mode=='disposed') {visible.value=false;}
      if(mode=='session') {container.read(authStateProvider.notifier).markAuthenticated();}
      if(mode=='service'){current=b;container.invalidate(xboardServiceProvider);}
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton,mode=='dismiss'?'再想想':'取消订单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds:400));
      final dispatched=mode=='normal'||mode.startsWith('late-');
      if(dispatched) {
        verify(()=>a.cancelOrder('fixture')).called(1);
        if(mode=='late-dispose') {visible.value=false;}
        if(mode=='late-session') {container.read(authStateProvider.notifier).markAuthenticated();}
        await tester.pump();response.complete(const XbSuccess(true));await tester.pumpAndSettle();
        if(mode=='late-session') {expect(find.text('有待支付订单'),findsOneWidget);}
      } else {
        verifyNever(()=>a.cancelOrder(any()));
      }
      verifyNever(()=>b.cancelOrder(any()));
      expect(tester.takeException(),isNull);
    });
   }
  }
 }
}
