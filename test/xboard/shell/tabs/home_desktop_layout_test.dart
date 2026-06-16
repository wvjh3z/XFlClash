/// C-分支桌面首页双栏布局几何测试。
///
/// 强制 `isMobileViewProvider=false`（桌面）+ 1280×800 视口，断言 HomeTab 走双栏分支：
/// 左栏（连接球 + 速率）在左、右栏（当前线路 / 代理模式 / 出口）在右，且内容居中限宽。
/// 等价 HTML 原型里用 getBoundingClientRect 量左右关系的做法（无图形环境下的可视化替代）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show PatchClashConfig, Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider, currentProfileProvider;
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_ip_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_line_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_mode_segment.dart';
import '../_net_detection_stub.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

Future<void> pumpDesktopHome(
  WidgetTester tester, {
  required AuthState auth,
}) async {
  // 桌面宽窗视口（1280×800）。
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final container = ProviderContainer(
    overrides: [
      // 强制桌面视图（不依赖 FlClash 的宽度阈值，测试确定性）。
      isMobileViewProvider.overrideWith((ref) => false),
      authStateProvider.overrideWith(() => _FakeAuth(auth)),
      isStartProvider.overrideWith((ref) => false),
      proxiesTabStateProvider.overrideWith((ref) => const ProxiesTabState(
            groups: [
              Group(
                type: GroupType.Selector,
                name: '智能优选',
                all: [Proxy(name: '香港01', type: 'ss')],
              ),
            ],
            currentGroupName: '智能优选',
            proxyCardType: ProxyCardType.expand,
            columns: 2,
          )),
      netDetectionOverride(),
      groupsProvider.overrideWithValue(const [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          now: '香港01',
          all: [Proxy(name: '香港01', type: 'ss')],
        ),
      ]),
      selectedMapProvider.overrideWith((ref) => const {'智能优选': '香港01'}),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider.overrideWithBuild(
          (ref, _) => const PatchClashConfig(mode: Mode.rule)),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: HomeTab())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('桌面已登录：左栏连接球/速率 + 右栏线路/模式/出口，左右分栏', (tester) async {
    await pumpDesktopHome(tester, auth: AuthState.authenticated);

    // 五个子组件齐全（连接球 + 速率磁贴 + 线路 + 模式 + 出口）。
    expect(find.byType(XbConnectOrb), findsOneWidget);
    // 桌面速率改为三个独立磁贴（原型 .mtiles）：下载/上传/延迟。
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('上传'), findsOneWidget);
    expect(find.text('延迟'), findsOneWidget);
    expect(find.byType(XbLineCard), findsOneWidget);
    expect(find.byType(XbModeSegment), findsOneWidget);
    expect(find.byType(XbIpCard), findsOneWidget);
    // 右栏带标题信息卡的标题（原型 .icard .ttl）。
    expect(find.text('当前线路'), findsOneWidget);
    expect(find.text('出口信息'), findsOneWidget);

    final orb = tester.getCenter(find.byType(XbConnectOrb));
    final line = tester.getCenter(find.byType(XbLineCard));
    final ip = tester.getCenter(find.byType(XbIpCard));

    // 连接球在左栏（屏幕中线左侧），线路/出口在右栏（中线右侧）。
    expect(orb.dx, lessThan(640), reason: '连接球应在左栏');
    expect(line.dx, greaterThan(640), reason: '当前线路应在右栏');
    expect(ip.dx, greaterThan(640), reason: '出口信息应在右栏');
    // 连接球明确在线路卡左侧。
    expect(orb.dx, lessThan(line.dx));

    // 内容居中限宽（maxWidth 1000）：右栏不贴到 1280 右边。
    final lineRight = tester.getTopRight(find.byType(XbLineCard)).dx;
    expect(lineRight, lessThan(1160), reason: '内容应限宽居中，不铺满窗口');
  });

  testWidgets('桌面游客：左栏连接球 + 右栏模式/出口，且不显示线路卡', (tester) async {
    await pumpDesktopHome(tester, auth: AuthState.unauthenticated);

    expect(find.byType(XbConnectOrb), findsOneWidget);
    expect(find.byType(XbModeSegment), findsOneWidget);
    expect(find.byType(XbIpCard), findsOneWidget);
    // 原型游客态无当前线路卡。
    expect(find.byType(XbLineCard), findsNothing);
    // 登录引导横幅通栏显示。
    expect(find.text('登录解锁全部功能'), findsOneWidget);

    final orb = tester.getCenter(find.byType(XbConnectOrb));
    final mode = tester.getCenter(find.byType(XbModeSegment));
    expect(orb.dx, lessThan(640), reason: '连接球应在左栏');
    expect(mode.dx, greaterThan(640), reason: '代理模式应在右栏');
  });
}
