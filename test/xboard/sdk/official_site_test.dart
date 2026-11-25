import 'dart:async';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:mocktail/mocktail.dart';
import '../../_fixtures/fake_xboard_sdk.dart';
import 'order_http_fixture.dart';

class _Config extends Mock implements sdk.ConfigApi {}

void main() {
  const path = '/api/v1/user/getQuickLoginUrl';
  const home = 'https://site.example/store/';
  late FakeXBoardSDK instance;
  late OrderFixtureHttp http;
  late _Config config;
  late XboardServiceImpl service;
  setUp(() {
    instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    http = OrderFixtureHttp(); config = _Config();
    when(() => instance.httpService).thenReturn(http);
    when(() => instance.config).thenReturn(config);
    when(config.getConfig).thenAnswer((_) async => const sdk.ConfigModel(appUrl: home));
    service = XboardServiceImpl(sdk: instance);
  });
  test('guests use the configured site without minting a login link', () async {
    instance.setupFor(XbScenario.loggedOut);
    when(() => instance.httpService).thenReturn(http);
    when(() => instance.config).thenReturn(config);
    final result = await XboardServiceImpl(sdk:instance).getOfficialSiteUrl(quickLogin:false,isActive:()=>true);
    expect(result.dataOrNull.toString(),home);
    verifyNever(() => http.postRequest(any(),any()));
  });
  test('each signed-in tap gets a fresh same-site login link', () async {
    var calls=0;
    when(() => http.postRequest(path,any())).thenAnswer((_) async => {'data':'$home#/login?verify=fixture${++calls}&redirect=dashboard'});
    for(var i=1;i<=2;i++) {
      final result=await service.getOfficialSiteUrl(quickLogin:true,isActive:()=>true);
      expect(result.dataOrNull?.fragment,'/login?verify=fixture$i&redirect=dashboard');
    }
  });
  test('a late response cannot launch after the session changes', () async {
    var active=true;
    final gate=Completer<Map<String,dynamic>>(), started=Completer<void>();
    when(() => http.postRequest(path,any())).thenAnswer((_){started.complete();return gate.future;});
    final result=service.getOfficialSiteUrl(quickLogin:true,isActive:()=>active);
    await started.future;active=false;gate.complete({'data':'$home#/login?verify=fixture&redirect=dashboard'});
    expect((await result).dataOrNull,isNull);
  });
  for(final bad in ['https://other.example/#/login?verify=fixture&redirect=dashboard','http://site.example/#/login?verify=fixture&redirect=dashboard',home]) {
    test('reject unexpected login destination $bad',() async {
      when(() => http.postRequest(path,any())).thenAnswer((_) async=>{'data':bad});
      expect((await service.getOfficialSiteUrl(quickLogin:true,isActive:()=>true)).dataOrNull,isNull);
    });
  }
}
