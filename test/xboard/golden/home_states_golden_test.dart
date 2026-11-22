/// 形态 A 首页连接态 golden 核对（游客 / 未连接 / 连接中 / 已连接）。
///
/// 用 CoreStatus + isStart 驱动连接球四态，渲染 golden 跟原型 home(state) 对比。不依赖模拟器。
library;

import 'golden_environment.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_line_card.dart';
import 'shell_fixture.dart';

Future<void> pumpHome(
  WidgetTester tester, {
  required AuthState auth,
  required CoreStatus core,
  required bool isStart,
  XbDomainSubscription? sub,
  XboardService? service,
}) async {
  await pumpShell(tester, core: core, auth: auth, mobile: true, size: const Size(390,844),
      subscription: sub, service: service, unselected: !isStart);
  expect(find.text('节点').hitTestable(), findsOneWidget);
  expect(find.text('商店').hitTestable(), findsOneWidget);
  expect(find.byType(XbLineCard), auth == AuthState.authenticated ? findsOneWidget : findsNothing);
  expect(Theme.of(tester.element(find.byType(Scaffold).first)).scaffoldBackgroundColor,
      const Color(0xFFEEEEEE));
}

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('首页 · 游客 golden', (t) async {
    await pumpHome(t,
        auth: AuthState.unauthenticated,
        core: CoreStatus.disconnected,
        isStart: false);
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/home_guest.png');
  });

  testWidgets('首页 · 已登录未连接 golden', (t) async {
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.disconnected,
        isStart: false);
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/home_ready.png');
  });

  testWidgets('首页 · 已连接 golden', (t) async {
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.connected,
        isStart: true);
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/home_connected.png');
  });

  testWidgets('首页 · 套餐到期提醒（剩7天）golden', (t) async {
    final now = DateTime.now();
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.connected,
        isStart: true,
        sub: _subExpiring(now.add(const Duration(days: 7, hours: 12))));
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/home_expiry_7d.png');
  });

  testWidgets('首页 · 套餐已过期 golden', (t) async {
    final now = DateTime.now();
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.connected,
        isStart: true,
        sub: _subExpiring(now.subtract(const Duration(days: 1))));
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/home_expiry_expired.png');
  });
}

/// 构造带指定到期时间的订阅（其余字段固定，避免像素漂移）。
XbDomainSubscription _subExpiring(DateTime expiredAt) => XbDomainSubscription(
      email: 'test@example.com',
      uuid: 'uuid-0000',
      planName: '标准套餐',
      totalBytes: 250 * 1024 * 1024 * 1024,
      usedBytes: 50 * 1024 * 1024 * 1024,
      expiredAt: expiredAt,
      planId: 1,
    );
