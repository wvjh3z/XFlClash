/// W8.3 — SentryBootstrap：dsn null no-op + beforeSend 脱敏 + 8 类 tag + opt-out。

import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';

void main() {
  setUp(SentryBootstrap.resetForTest);

  group('installEarly no-op', () {
    test('dsn null → 不启用', () async {
      await SentryBootstrap.installEarly(dsn: null, release: '1.0');
      expect(SentryBootstrap.isEnabled, isFalse);
    });
    test('dsn 空串 → 不启用', () async {
      await SentryBootstrap.installEarly(dsn: '', release: '1.0');
      expect(SentryBootstrap.isEnabled, isFalse);
    });
    test('dsn 非空 + 未 opt-out → 启用', () async {
      await SentryBootstrap.installEarly(dsn: 'https://x@sentry.io/1', release: '1.0');
      expect(SentryBootstrap.isEnabled, isTrue);
    });
    test('dsn 非空但 userOptedOut → 不启用（κ-4）', () async {
      await SentryBootstrap.installEarly(
          dsn: 'https://x@sentry.io/1', release: '1.0', userOptedOut: true);
      expect(SentryBootstrap.isEnabled, isFalse);
    });
  });

  group('scrubData beforeSend 脱敏（κ-4 / § C）', () {
    test('敏感字段值替换 ***', () {
      final out = SentryBootstrap.scrubData({
        'token': 'secret',
        'password': 'pw',
        'email': 'a@b.com',
        'uuid': 'xxx',
        'plan': 'Pro', // 非敏感保留
      });
      expect(out['token'], '***');
      expect(out['password'], '***');
      expect(out['email'], '***');
      expect(out['uuid'], '***');
      expect(out['plan'], 'Pro');
    });
    test('嵌套 map 递归脱敏', () {
      final out = SentryBootstrap.scrubData({
        'data': {'auth_data': 'Bearer xxx', 'name': 'ok'},
      });
      expect((out['data'] as Map)['auth_data'], '***');
      expect((out['data'] as Map)['name'], 'ok');
    });
    test('部分匹配（Authorization 含 authorization）', () {
      final out = SentryBootstrap.scrubData({'Authorization': 'Bearer x'});
      expect(out['Authorization'], '***');
    });
  });

  group('DD-23 8 类 tag', () {
    test('tagBootstrap stage/source/failure', () {
      SentryBootstrap.tagBootstrap(
          stage: 'async', envelopeSource: 'cache', decryptionFailure: 'tagError');
      final t = SentryBootstrap.tagsSnapshot;
      expect(t[SentryTagKeys.bootstrapStage], 'async');
      expect(t[SentryTagKeys.envelopeSource], 'cache');
      expect(t[SentryTagKeys.decryptionFailure], 'tagError');
    });
    test('tagEndpoint current/raceAttempts', () {
      SentryBootstrap.tagEndpoint(current: 'https://api', raceAttempts: 3);
      final t = SentryBootstrap.tagsSnapshot;
      expect(t[SentryTagKeys.endpointCurrent], 'https://api');
      expect(t[SentryTagKeys.endpointRaceAttempts], '3');
    });
  });

  group('opt-out（κ-4）', () {
    test('setUserOptOut(true) → 关闭', () async {
      await SentryBootstrap.installEarly(dsn: 'https://x@sentry.io/1', release: '1.0');
      await SentryBootstrap.setUserOptOut(true);
      expect(SentryBootstrap.isEnabled, isFalse);
    });
    test('setUserOptOut(false) 后恢复（dsn 仍在）', () async {
      await SentryBootstrap.installEarly(dsn: 'https://x@sentry.io/1', release: '1.0');
      await SentryBootstrap.setUserOptOut(true);
      await SentryBootstrap.setUserOptOut(false);
      expect(SentryBootstrap.isEnabled, isTrue);
    });
  });
}
