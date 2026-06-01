/// W8.9 — 可观测性/i18n 端到端（真机/模拟器）：WarningBanner + Sentry no-op + locale 解析。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fl_clash/xboard/l10n/content_language.dart';
import 'package:fl_clash/xboard/l10n/xboard_locale_resolution.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:fl_clash/xboard/widgets/warning_banner.dart';

import '_fake_integration_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('W8.9 WarningBanner：超额订阅 → 显示流量用尽（device 渲染）', (t) async {
    final fake = _OverQuotaService();
    await t.pumpWidget(ProviderScope(
      overrides: [xboardServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: Scaffold(body: WarningBanner())),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('流量已用尽'), findsOneWidget);
  });

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

/// 超额订阅 fake（覆盖 getSubscription：已用 = 总量 → overQuota）。
class _OverQuotaService extends FakeIntegrationService {
  @override
  Future<XbResult<XbDomainSubscription>> getSubscription() async {
    return XbResult.success(const XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'over-quota',
      planName: '专业版套餐',
      totalBytes: 100,
      usedBytes: 100, // 已用 = 总量 → overQuota
    ));
  }
}
