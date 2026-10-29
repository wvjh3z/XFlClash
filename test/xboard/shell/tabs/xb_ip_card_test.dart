/// 出口 IP 卡 XbIpCard + XbNetworkAdapter 投影。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/adapters/xb_network_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_ip_card.dart';

class _FakeNetwork extends XbNetworkAdapter {
  const _FakeNetwork(this.status);
  final XbIpStatus status;
  @override
  XbIpStatus ipStatus(WidgetRef ref) => status;
  @override
  void forceCheck(WidgetRef ref) {}
}

Future<void> _pump(WidgetTester t, XbIpStatus status) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        xbNetworkAdapterProvider.overrideWithValue(_FakeNetwork(status)),
      ],
      child: const MaterialApp(home: Scaffold(body: XbIpCard())),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets('有 IP（香港）→ 国旗 + 出口 IP (香港) + IP 值', (t) async {
    await _pump(
      t,
      const XbIpStatus(loading: false, ip: '47.243.10.20', countryCode: 'HK'),
    );
    expect(find.text('出口 IP (香港)'), findsOneWidget);
    expect(find.text('47.243.10.20'), findsOneWidget);
    expect(find.text('🇭🇰', findRichText: true), findsOneWidget);
  });

  testWidgets('未连接本地 IP（中国）→ 出口 IP (中国)', (t) async {
    await _pump(
      t,
      const XbIpStatus(loading: false, ip: '113.96.1.2', countryCode: 'CN'),
    );
    expect(find.text('出口 IP (中国)'), findsOneWidget);
    expect(find.text('113.96.1.2'), findsOneWidget);
  });

  testWidgets('检测中（无旧值）→ 检测中… + 转圈', (t) async {
    await _pump(t, const XbIpStatus(loading: true, ip: null));
    expect(find.text('检测中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('出口 IP'), findsOneWidget); // 无国家括号
  });

  testWidgets('后台复核显示标注的上次 IP', (t) async {
    await _pump(t, const XbIpStatus(loading: true, ip: '203.0.113.1', countryCode: 'HK'));
    expect(find.text('检测中…'), findsNothing);
    expect(find.text('203.0.113.1'), findsOneWidget);
    expect(find.textContaining('上次结果，复核中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('检测失败（非加载 + 无 IP）→ 检测失败', (t) async {
    await _pump(t, const XbIpStatus(loading: false, ip: null));
    expect(find.text('检测失败'), findsOneWidget);
  });

  testWidgets('未知国家码 → 回退显示码本身', (t) async {
    await _pump(
      t,
      const XbIpStatus(loading: false, ip: '1.2.3.4', countryCode: 'ZZ'),
    );
    expect(find.text('出口 IP (ZZ)'), findsOneWidget);
  });
}
