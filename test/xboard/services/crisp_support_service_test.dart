/// D9 — CrispSupportService 单测（入口显隐 / 来源平台 / 永不抛）。
///
/// 注：openCrispChat 走平台 channel，测试环境无插件实现 → 调用会抛 MissingPluginException，
/// 服务内部全捕获返 false（验证「永不抛」契约）。会话数据透传的具体值由真机/手测核对。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/services/crisp_support_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(XboardConfig.resetForTest);

  /// crisp_chat 平台 channel：测试里 mock 成 no-op（返 null），避免 fire-and-forget 的
  /// setSessionString/openCrispChat 抛 MissingPluginException（异步未捕获会拖垮测试）。
  const channel = MethodChannel('flutter_crisp_chat');
  void mockCrispChannel(Object? Function(MethodCall)? handler) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler == null ? null : (c) async => handler(c));
  }

  tearDown(() => mockCrispChannel(null));

  XboardConfig _cfg({required String crispWebsiteId}) => XboardConfig(
        subscribeUserAgent: 'x flclash',
        devApiEndpoint: 'https://x',
        devSubscriptionEndpoint: 'https://x',
        debug: false,
        kIsTest: true,
        crispWebsiteId: crispWebsiteId,
      );

  group('isEnabled', () {
    test('websiteId 空 → false（入口隐藏）', () {
      XboardConfig.bind(_cfg(crispWebsiteId: ''));
      expect(CrispSupportService.isEnabled, isFalse);
    });

    test('websiteId 仅空白 → false', () {
      XboardConfig.bind(_cfg(crispWebsiteId: '   '));
      expect(CrispSupportService.isEnabled, isFalse);
    });

    test('websiteId 有值 → true', () {
      XboardConfig.bind(_cfg(crispWebsiteId: 'ws-abc-123'));
      expect(CrispSupportService.isEnabled, isTrue);
    });
  });

  test('sourcePlatform 非空（平台名）', () {
    expect(CrispSupportService.sourcePlatform, isNotEmpty);
    expect(
        ['Android', 'iOS', 'Windows', 'macOS', 'Linux', '未知'],
        contains(CrispSupportService.sourcePlatform));
  });

  group('open', () {
    test('websiteId 空 → 直接返 false（不调平台）', () async {
      XboardConfig.bind(_cfg(crispWebsiteId: ''));
      expect(await CrispSupportService.open(), isFalse);
    });

    test('websiteId 有值 + 已登录 → 调平台成功返 true，且透传会话数据', () async {
      XboardConfig.bind(_cfg(crispWebsiteId: 'ws-abc-123'));
      final calls = <MethodCall>[];
      mockCrispChannel((c) {
        calls.add(c);
        // session 立即就绪 → 轮询第一次即命中，触发会话数据写入。
        if (c.method == 'getSessionIdentifier') return 'sess-1';
        return null;
      });
      final sub = XbDomainSubscription(
        email: 'demo@example.com',
        uuid: 'u1',
        planName: '专业版',
        totalBytes: 100 * 1024 * 1024 * 1024,
        usedBytes: 90 * 1024 * 1024 * 1024,
        expiredAt: DateTime(2026, 12, 31),
        planId: 1,
      );
      expect(await CrispSupportService.open(sub: sub), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50)); // 等后台轮询写完会话数据
      final methods = calls.map((c) => c.method).toList();
      expect(methods, contains('setSessionString'));
      expect(methods, contains('openCrispChat'));
      // 锁死顺序：openCrispChat（=Crisp.configure）必须在 setSessionString 之前，
      // 且 setSessionString 在 session 就绪（getSessionIdentifier 命中）之后。
      expect(methods.indexOf('openCrispChat') < methods.indexOf('setSessionString'),
          isTrue,
          reason: 'setSessionString 必须在 openCrispChat/configure 之后调');
      final strKeys = calls
          .where((c) => c.method == 'setSessionString')
          .map((c) => (c.arguments as Map)['key'])
          .toList();
      // 字段名对齐 Crisp_bot/EZ-Xbaord：Email/Plan/Expires/Traffic + Source。
      expect(strKeys,
          containsAll(['Email', 'Plan', 'Expires', 'Traffic', 'Source']));
      // 不再发 used_percent / 小写旧键。
      expect(strKeys, isNot(contains('used_percent')));
      expect(strKeys, isNot(contains('plan')));
      // Source 带客户端版本，格式 `平台(v...)`，如 Android(v0.0.1-...)。
      final source = calls.firstWhere((c) =>
          c.method == 'setSessionString' &&
          (c.arguments as Map)['key'] == 'Source');
      final srcVal = (source.arguments as Map)['value'] as String;
      expect(srcVal, contains('(v'));
      expect(srcVal, endsWith(')'));
    });

    test('游客（sub=null）→ 仅带来源，仍返 true', () async {
      XboardConfig.bind(_cfg(crispWebsiteId: 'ws-abc-123'));
      final calls = <MethodCall>[];
      mockCrispChannel((c) {
        calls.add(c);
        if (c.method == 'getSessionIdentifier') return 'sess-1';
        return null;
      });
      expect(await CrispSupportService.open(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50)); // 等后台轮询写完会话数据
      final strKeys = calls
          .where((c) => c.method == 'setSessionString')
          .map((c) => (c.arguments as Map)['key'])
          .toList();
      expect(strKeys, contains('Source'));
      expect(strKeys, isNot(contains('Plan')), reason: '游客不带套餐数据');
    });

    test('平台抛异常 → 捕获返 false（永不抛）', () async {
      XboardConfig.bind(_cfg(crispWebsiteId: 'ws-abc-123'));
      mockCrispChannel((c) {
        if (c.method == 'openCrispChat') {
          throw PlatformException(code: 'boom');
        }
        return null;
      });
      expect(await CrispSupportService.open(), isFalse);
    });
  });

  group('reset（登出/换号清会话）', () {
    test('调 resetCrispChatSession 平台方法', () async {
      final calls = <MethodCall>[];
      mockCrispChannel((c) {
        calls.add(c);
        return null;
      });
      await CrispSupportService.reset();
      expect(calls.map((c) => c.method), contains('resetCrispChatSession'));
    });

    test('平台抛异常 → 静默吞掉（永不抛）', () async {
      mockCrispChannel((c) => throw PlatformException(code: 'no-session'));
      // 不应抛。
      await CrispSupportService.reset();
    });
  });
}
