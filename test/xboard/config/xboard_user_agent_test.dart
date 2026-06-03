/// R4.4 — XboardUserAgent：每平台固定真实浏览器 UA（无 flclash 特征串）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/config/xboard_user_agent.dart';

void main() {
  group('XboardUserAgent — 每平台固定真实浏览器 UA', () {
    test('5 平台 UA 都不含 flclash 特征串（伪装关键）', () {
      for (final ua in [
        XboardUserAgent.android,
        XboardUserAgent.ios,
        XboardUserAgent.windows,
        XboardUserAgent.macos,
        XboardUserAgent.linux,
      ]) {
        expect(ua.toLowerCase().contains('flclash'), isFalse, reason: ua);
        expect(ua.startsWith('Mozilla/5.0'), isTrue, reason: ua);
      }
    });

    test('Android UA = Chrome on Android', () {
      expect(XboardUserAgent.android, contains('Android'));
      expect(XboardUserAgent.android, contains('Chrome/'));
      expect(XboardUserAgent.android, contains('Mobile'));
    });

    test('iOS UA = Safari on iPhone', () {
      expect(XboardUserAgent.ios, contains('iPhone'));
      expect(XboardUserAgent.ios, contains('Safari'));
    });

    test('Windows / macOS / Linux 桌面 UA', () {
      expect(XboardUserAgent.windows, contains('Windows NT'));
      expect(XboardUserAgent.macos, contains('Macintosh'));
      expect(XboardUserAgent.linux, contains('X11; Linux'));
    });

    test('forPlatform 分发正确', () {
      expect(XboardUserAgent.forPlatform('android'), XboardUserAgent.android);
      expect(XboardUserAgent.forPlatform('iOS'), XboardUserAgent.ios);
      expect(XboardUserAgent.forPlatform('Windows'), XboardUserAgent.windows);
      expect(XboardUserAgent.forPlatform('macos'), XboardUserAgent.macos);
      expect(XboardUserAgent.forPlatform('linux'), XboardUserAgent.linux);
    });

    test('forPlatform 未知平台 → fallback（Windows Chrome）', () {
      expect(XboardUserAgent.forPlatform('haiku'), XboardUserAgent.fallback);
      expect(XboardUserAgent.fallback, XboardUserAgent.windows);
    });

    test('current 返回当前平台 UA（测试 host = Linux）', () {
      // 测试在 Linux host 跑 → current 应等于 linux UA。
      expect(XboardUserAgent.current, XboardUserAgent.linux);
    });
  });
}
