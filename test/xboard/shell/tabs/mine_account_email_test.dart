/// 账号卡顶行：套餐名优先完整显示，邮箱占「套餐名之外的真实剩余空间」（不与套餐名平分）。
///
/// 回归「邮箱被过早省略」bug：根因是套餐名/邮箱都 flex=1 平分空间，套餐名省下的宽被浪费、
/// 邮箱被框小 → 没超界也省略。修复：套餐名 Flexible(flex:0) 按内容占宽，邮箱 Expanded 占真实剩余。
///
/// 注：widget 测试用 Ahem 字体（每字符宽=fontSize），文本物理宽远大于真机真实字体，故不以
/// 「是否省略」断言（Ahem 下中等邮箱也会超），而是断言**邮箱分到的宽度 ≈ 套餐名之外的剩余**，
/// 直接证明空间没被平分（这才是 bug 的根因）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._s);
  final AuthState _s;
  @override
  AuthState build() => _s;
}

XbDomainSubscription _sub(String email, {String plan = '专业版'}) =>
    XbDomainSubscription(
      email: email,
      uuid: 'u',
      planName: plan,
      totalBytes: 100 * 1024 * 1024 * 1024,
      usedBytes: 37 * 1024 * 1024 * 1024,
      expiredAt: DateTime(2026, 12, 31),
      planId: 1,
    );

Future<void> _pump(WidgetTester tester, String email,
    {double width = 390, String plan = '专业版'}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
        userProfileProvider.overrideWith((ref) async => _sub(email, plan: plan)),
      ],
      child: const MaterialApp(home: Scaffold(body: MineTab())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

double _w(WidgetTester tester, Finder f) =>
    (tester.renderObject(f) as RenderBox).size.width;

void main() {
  testWidgets('邮箱占套餐名之外的剩余空间（不与套餐名平分）', (tester) async {
    const email = 'demo@example.com';
    await _pump(tester, email);
    final planW = _w(tester, find.text('专业版'));
    final mailW = _w(tester, find.text(email));
    // 邮箱宽必须远大于「平分一半」——即套餐名占用很小时，邮箱拿到大部分剩余。
    // 若被平分（旧 bug），邮箱 ≈ 卡内宽/2；修复后邮箱 ≈ 卡内宽 - 套餐名 - gap。
    expect(mailW, greaterThan(planW * 2),
        reason: '邮箱应占大部分行宽（套餐名很短），而非与套餐名平分');
  });

  testWidgets('短邮箱（390）→ 完整不省略', (tester) async {
    const email = 'demo@example.com';
    await _pump(tester, email);
    final ro = tester.renderObject(find.text(email)) as RenderParagraph;
    expect(ro.didExceedMaxLines, isFalse);
  });

  testWidgets('套餐名优先：长套餐名能放下 → 套餐名完整（邮箱让位）', (tester) async {
    const email = 'a-very-long-email-1234567890@some-domain.example.com';
    await _pump(tester, email, plan: '尊享会员');
    final ro = tester.renderObject(find.text('尊享会员')) as RenderParagraph;
    expect(ro.didExceedMaxLines, isFalse, reason: '套餐名优先完整显示');
  });
}
