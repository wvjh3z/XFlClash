/// C-分支桌面「我的」双栏布局几何测试。
///
/// 宽窗口（1280×800）下断言 MineTab 走双栏：左栏 = 账户组（含信息卡），右栏 = 应用组；
/// 「账户」标签在「应用」标签左侧，账户项（我的订单）在应用项（设置）左侧。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

XbDomainSubscription _sub() => XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'uid-1',
      planName: '专业版',
      totalBytes: 100 * 1024 * 1024 * 1024,
      usedBytes: 30 * 1024 * 1024 * 1024,
      expiredAt: DateTime(2026, 12, 31),
      planId: 1,
    );

Future<void> pumpDesktopMine(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider
            .overrideWith(() => _FakeAuth(AuthState.authenticated)),
        userProfileProvider.overrideWith((ref) async => _sub()),
      ],
      child: const MaterialApp(home: Scaffold(body: MineTab())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  testWidgets('桌面：左账户组（含信息卡）+ 右应用组，左右分栏', (tester) async {
    await pumpDesktopMine(tester);

    // 账户信息卡在左栏（套餐名可见）。
    expect(find.text('专业版'), findsOneWidget);
    // 账户组 / 应用组标签都在。
    expect(find.text('账户'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);

    final acc = tester.getCenter(find.text('账户'));
    final app = tester.getCenter(find.text('应用'));
    expect(acc.dx, lessThan(app.dx), reason: '账户组应在左栏、应用组在右栏');

    // 账户项「我的订单」在左，应用项「关于」在右（设置已移到独立「设置」Tab，我的页不再有）。
    final order = tester.getCenter(find.text('我的订单'));
    final about = tester.getCenter(find.text('关于'));
    expect(order.dx, lessThan(about.dx), reason: '我的订单(账户左) 应在 关于(应用右) 左侧');
    // 设置入口已从「我的」Tab 移除（桌面有独立设置 Tab）。
    expect(find.text('设置'), findsNothing);

    // 信息卡（套餐名）也在左栏。
    final plan = tester.getCenter(find.text('专业版'));
    expect(plan.dx, lessThan(app.dx), reason: '信息卡应在左栏');
  });
}
