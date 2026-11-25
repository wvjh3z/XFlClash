import 'dart:async';
import 'package:crisp_chat/crisp_chat.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/services/crisp_chat_driver.dart';
import 'package:fl_clash/xboard/services/crisp_client_ip.dart';
import 'package:fl_clash/xboard/services/crisp_support_service.dart';
import 'package:fl_clash/xboard/services/exit_ip_probe.dart';

class _Driver implements CrispChatDriver {
  String sid = 'fixture-session';
  final writes = <String>[];
  bool failIp = false;
  @override Stream<void> get sessionLoaded => const Stream.empty();
  @override Future<String?> sessionId() async => sid;
  @override Future<void> open(CrispConfig config) async {}
  @override Future<void> reset(String websiteId) async {}
  @override Future<void> setString(String key, String value) async {
    if (key != 'client_ip') return;
    if (failIp) throw StateError('fixture');
    writes.add(value);
  }
}
void main() {
  test('only a fresh mainland public IPv4 qualifies', () {
    for (final c in ['HK', 'MO', 'TW', 'US', null]) {
      expect(crispClientIp(XbExitIpResult('1.2.3.4', c)), isNull);
    }
    for (final ip in ['10.1.2.3','192.168.1.1','100.64.0.1','127.0.0.1','::1',
      '2001:db8::1','0.0.0.0','203.0.113.3','224.1.1.1','invalid']) {
      expect(crispClientIp(XbExitIpResult(ip,'CN')),isNull);
    }
    expect(crispClientIp(const XbExitIpResult('1.2.3.4','CN')),'1.2.3.4');
  });
  test('late updates are optional, scoped, and cleared; guests never send IP', () async {
    final driver = _Driver();
    final ip = ValueNotifier<String?>(null);
    XboardConfig.bind(const XboardConfig(subscribeUserAgent:'fixture',devApiEndpoint:'',devSubscriptionEndpoint:'',debug:false,kIsTest:true,crispWebsiteId:'fixture'));
    await CrispSupportService.setDriverForTest(driver);
    addTearDown(() async { await CrispSupportService.reset();ip.dispose();XboardConfig.resetForTest(); });
    const sub = XbDomainSubscription(email:'fixture@example.invalid',uuid:'fixture',totalBytes:0,usedBytes:0);
    Future<void> drain() => Future<void>.delayed(Duration.zero);
    bool owner = true;
    final opened = await CrispSupportService.openWithResult(sub:sub,clientIp:ip,ipOwnerCurrent:()=>owner);
    expect(opened.opened,isTrue); await drain(); expect(driver.writes,['']);
    ip.value='1.2.3.4'; await drain();expect(driver.writes.last,'1.2.3.4');
    ip.value=null;await drain();expect(driver.writes.last,'');
    driver.sid='new';ip.value='1.2.3.5';await drain();expect(driver.writes,hasLength(3));
    driver.sid='fixture-session';owner=false;ip.value='1.2.3.6';await drain();expect(driver.writes,hasLength(3));
    owner=true;driver.failIp=true;
    expect((await CrispSupportService.openWithResult(sub:sub,clientIp:ip)).opened,isTrue);
    await drain();await CrispSupportService.reset();driver.failIp=false;
    expect((await CrispSupportService.openWithResult(clientIp:ip)).opened,isTrue);
    ip.value='1.2.3.7';await drain();expect(driver.writes,hasLength(3));
  });
}
