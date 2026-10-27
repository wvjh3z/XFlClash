import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/sheets/register_sheet.dart';
import 'package:fl_clash/xboard/shell/sheets/sheet_scaffold.dart';
import 'package:fl_clash/xboard/shell/sheets/forgot_pwd_sheet.dart';
class _Service extends Mock implements XboardService {}
class _Ready extends BootstrapReady {
  @override bool build() => true;
}
void main() {
 for(final brand in ['brand_a','brand_b']) {
  for(final forgot in [false,true]) {
   for(final mode in ['late-full','late-prefix','outside','double-at','typing-at','submit','submit-outside']) {
    testWidgets('$brand forgot=$forgot email $mode',(tester)async {
      tester.view.physicalSize=const Size(800,1000);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.reset);
      XboardConfig.bind(XboardConfig(appName:brand,flavorId:brand,subscribeUserAgent:'fixture',devApiEndpoint:'',devSubscriptionEndpoint:'',debug:true,kIsTest:true,formA:true));
      addTearDown(XboardConfig.resetForTest);
      final service=_Service();final gate=Completer<List<String>>();String? sent;
      when(()=>service.sendEmailVerifyCode(any())).thenAnswer((call)async {
        sent=call.positionalArguments.first as String;
        return const XbFailure(XbBusiness(XbBusinessKind.generic,'fixture rejected',null));
      });
      when(()=>service.register(any(),any(),emailCode:any(named:'emailCode'),inviteCode:any(named:'inviteCode'))).thenAnswer((call)async {
        sent=call.positionalArguments.first as String;
        return const XbFailure(XbBusiness(XbBusinessKind.generic,'fixture rejected',null));
      });
      when(()=>service.forgotPassword(any(),any(),any())).thenAnswer((call)async {
        sent=call.positionalArguments.first as String;
        return const XbFailure(XbBusiness(XbBusinessKind.generic,'fixture rejected',null));
      });
      await tester.pumpWidget(ProviderScope(overrides:[bootstrapReadyProvider.overrideWith(_Ready.new),xboardServiceProvider.overrideWithValue(service),emailSuffixesProvider.overrideWith((ref)=>gate.future)],
       child:MaterialApp(home:Scaffold(body:forgot?const ForgotPwdSheet():const RegisterSheet()))));
      await tester.pump();
      final text=switch(mode){'late-prefix'||'typing-at'=>'fixture','outside'||'submit-outside'=>'fixture@other.test','double-at'=>'fixture@@example.test',_=>'fixture@example.test'};
      await tester.enterText(find.byType(TextField).first,text);
      gate.complete(['example.test']);await tester.pumpAndSettle();
      if(mode=='typing-at') {
        await tester.enterText(find.byType(TextField).first,'fixture@example.test');await tester.pump();
        expect(tester.widget<EditableText>(find.byType(EditableText).first).focusNode.hasFocus,isTrue);
      }
      if(mode!='late-prefix') {expect(find.byType(DropdownButtonFormField<String>),findsNothing);}
      if (mode.startsWith('submit')) {
        await tester.enterText(find.byType(TextField).at(1),'123456');
        await tester.enterText(find.byType(TextField).at(2),'fixture-password');
        await tester.tap(find.widgetWithText(FilledButton,forgot?'重置密码':'注册'));
      } else {
        await tester.tap(find.text('获取验证码'));
      }
      await tester.pump();
      expect(sent,mode=='outside'||mode=='submit-outside'||mode=='double-at'?isNull:'fixture@example.test');
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());
    });
   }
  }
 }
 testWidgets('removed selected suffix resets displayed choice without losing text', (tester) async {
   final input = TextEditingController(text:'fixture');
   final choices = ValueNotifier<List<String>>(['old.test']);
   addTearDown(input.dispose);addTearDown(choices.dispose);
   await tester.pumpWidget(MaterialApp(home:Scaffold(body:ValueListenableBuilder<List<String>>(
     valueListenable:choices,
     builder:(context,value,_)=>XbEmailAccountField(prefixController:input,suffixes:value,selectedSuffix:'old.test',onSuffixChanged:(_){}),
   ))));
   await tester.pumpAndSettle();
   expect(find.text('@old.test'), findsOneWidget);
   choices.value=['new.test'];await tester.pumpAndSettle();
   expect(find.text('@new.test'), findsOneWidget);
   expect(input.text,'fixture');expect(tester.takeException(),isNull);
 });

}
