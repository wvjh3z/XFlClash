/// XbExpiryCard 逻辑单测：注入不同到期时间，断言显示/隐藏 + 文案。
///
/// 边界：>7天不显示 / =7天显示「仅剩7天」/ ≤3天紧急 / <1天显示小时 / 已过期 /
/// 长期有效(expiredAt==null)不显示 / 游客不显示 / 订阅失败不显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_expiry_card.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

XbDomainSubscription _sub(DateTime? expiredAt) => XbDomainSubscription(
      email: 't@e.com',
      uuid: 'u',
      totalBytes: 1000,
      usedBytes: 100,
      expiredAt: expiredAt,
      planId: 1,
    );

Future<void> pumpCard(
  WidgetTester tester, {
  required AuthState auth,
  Object? profileOverride, // XbDomainSubscription | Future.error | null(不override)
}) async {
  final overrides = [
    authStateProvider.overrideWith(() => _FakeAuth(auth)),
  ];
  if (profileOverride is XbDomainSubscription) {
    overrides.add(
        userProfileProvider.overrideWith((ref) => Future.value(profileOverride)));
  } else if (profileOverride == 'error') {
    overrides.add(userProfileProvider
        .overrideWith((ref) => Future.error(Exception('fail'))));
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(
          body: XbBrandTheme(
            brandColor: Color(0xFFD92E1A),
            child: XbExpiryCard(),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // 让 FutureProvider resolve
  await tester.pump();
}

void main() {
  final now = DateTime.now();

  testWidgets('游客 → 不显示', (t) async {
    await pumpCard(t,
        auth: AuthState.unauthenticated,
        profileOverride: _sub(now.add(const Duration(days: 2))));
    expect(find.textContaining('套餐'), findsNothing);
  });

  testWidgets('长期有效(expiredAt==null) → 不显示', (t) async {
    await pumpCard(t, auth: AuthState.authenticated, profileOverride: _sub(null));
    expect(find.textContaining('套餐'), findsNothing);
  });

  testWidgets('剩余 >7 天 → 不显示', (t) async {
    await pumpCard(t,
        auth: AuthState.authenticated,
        profileOverride: _sub(now.add(const Duration(days: 30))));
    expect(find.textContaining('套餐'), findsNothing);
  });

  testWidgets('剩余 7 天 → 显示「仅剩 7 天」+ 去续费', (t) async {
    await pumpCard(t,
        auth: AuthState.authenticated,
        profileOverride: _sub(now.add(const Duration(days: 7, hours: 12))));
    expect(find.textContaining('套餐即将到期'), findsOneWidget);
    expect(find.textContaining('仅剩 7 天'), findsOneWidget);
    expect(find.text('去续费'), findsOneWidget);
  });

  testWidgets('剩余 2 天 → 紧急「仅剩 2 天」', (t) async {
    await pumpCard(t,
        auth: AuthState.authenticated,
        profileOverride: _sub(now.add(const Duration(days: 2, hours: 12))));
    expect(find.textContaining('仅剩 2 天'), findsOneWidget);
  });

  testWidgets('剩余 7 小时 → 显示小时', (t) async {
    await pumpCard(t,
        auth: AuthState.authenticated,
        profileOverride: _sub(now.add(const Duration(hours: 7))));
    expect(find.textContaining('小时'), findsOneWidget);
  });

  testWidgets('已过期 → 显示「套餐已过期」', (t) async {
    await pumpCard(t,
        auth: AuthState.authenticated,
        profileOverride: _sub(now.subtract(const Duration(days: 1))));
    expect(find.text('套餐已过期'), findsOneWidget);
    expect(find.text('去续费'), findsOneWidget);
  });

  testWidgets('订阅加载失败 → 不显示（不打扰）', (t) async {
    await pumpCard(t, auth: AuthState.authenticated, profileOverride: 'error');
    expect(find.textContaining('套餐'), findsNothing);
  });

  testWidgets('点「去续费」→ 触发 onTapRenew', (t) async {
    var tapped = false;
    await tester(t, onTapRenew: () => tapped = true);
    await t.tap(find.text('去续费'));
    expect(tapped, isTrue);
  });
}

/// 带 onTapRenew 回调的 pump（单独，验证点击）。
Future<void> tester(WidgetTester t,
    {required VoidCallback onTapRenew}) async {
  final now = DateTime.now();
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
        userProfileProvider.overrideWith(
            (ref) => Future.value(_sub(now.add(const Duration(days: 2))))),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: XbBrandTheme(
            brandColor: const Color(0xFFD92E1A),
            child: XbExpiryCard(onTapRenew: onTapRenew),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}
