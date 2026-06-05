/// W8.9 — 可观测性/i18n 端到端（真机/模拟器）：Sentry no-op + locale 解析。
///
/// 注：原 WarningBanner 用例随形态 B `warning_banner` 删除一并移除（形态 A 不再用该横幅；
/// 流量/到期提醒已并入「我的」Tab 账号卡）。本文件保留的是形态 A 仍依赖的可观测性 / i18n 地基。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fl_clash/xboard/l10n/content_language.dart';
import 'package:fl_clash/xboard/l10n/xboard_locale_resolution.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('W8.9 Sentry dsn null → no-op（device）', (t) async {
    SentryBootstrap.resetForTest();
    await SentryBootstrap.installEarly(dsn: null, release: '1.0');
    expect(SentryBootstrap.isEnabled, isFalse);
    // 脱敏纯函数在 device 行为一致。
    final scrubbed = SentryBootstrap.scrubData({'token': 'x', 'plan': 'Pro'});
    expect(scrubbed['token'], '***');
    expect(scrubbed['plan'], 'Pro');
  });

  testWidgets('W8.9/W8.8 三层 locale 一致性（device）', (t) async {
    final ui = resolveXboardLocale(const Locale('zh'), kXboardSupportedLocales);
    expect('${ui.languageCode}-${ui.countryCode}', 'zh-CN');
    expect(mapToBackendLocale('zh'), 'zh-CN');
    expect(mapToBackendLocale('ja'), 'en-US');
  });
}
