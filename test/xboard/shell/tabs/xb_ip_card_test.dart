/// 出口 IP 卡 XbIpCard + XbNetworkAdapter 投影。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/models/models.dart' show IpInfo, NetworkDetectionState;
import 'package:fl_clash/providers/app.dart'
    show networkDetectionProvider, NetworkDetection;
import 'package:fl_clash/xboard/shell/adapters/xb_network_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_ip_card.dart';

/// 用 override networkDetectionProvider 的 state 注入假数据。
/// （Notifier provider 无法直接 overrideWithValue state，用 overrideWith 提供假 Notifier。）
class _FakeNetDetection extends NetworkDetection {
  _FakeNetDetection(this._state);
  final NetworkDetectionState _state;
  @override
  NetworkDetectionState build() => _state;
}

Future<void> _pump(WidgetTester t, NetworkDetectionState s) async {
  await t.pumpWidget(ProviderScope(
    overrides: [
      networkDetectionProvider.overrideWith(() => _FakeNetDetection(s)),
    ],
    child: const MaterialApp(home: Scaffold(body: XbIpCard())),
  ));
  await t.pump();
}

void main() {
  testWidgets('有 IP（香港）→ 国旗 + 出口 IP (香港) + IP 值', (t) async {
    await _pump(
      t,
      const NetworkDetectionState(
        isLoading: false,
        ipInfo: IpInfo(ip: '47.243.10.20', countryCode: 'HK'),
      ),
    );
    expect(find.text('出口 IP (香港)'), findsOneWidget);
    expect(find.text('47.243.10.20'), findsOneWidget);
    expect(find.text('🇭🇰'), findsOneWidget);
  });

  testWidgets('未连接本地 IP（中国）→ 出口 IP (中国)', (t) async {
    await _pump(
      t,
      const NetworkDetectionState(
        isLoading: false,
        ipInfo: IpInfo(ip: '113.96.1.2', countryCode: 'CN'),
      ),
    );
    expect(find.text('出口 IP (中国)'), findsOneWidget);
    expect(find.text('113.96.1.2'), findsOneWidget);
  });

  testWidgets('检测中（无旧值）→ 检测中… + 转圈', (t) async {
    await _pump(
      t,
      const NetworkDetectionState(isLoading: true, ipInfo: null),
    );
    expect(find.text('检测中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('出口 IP'), findsOneWidget); // 无国家括号
  });

  testWidgets('检测失败（非加载 + 无 IP）→ 检测失败', (t) async {
    await _pump(
      t,
      const NetworkDetectionState(isLoading: false, ipInfo: null),
    );
    expect(find.text('检测失败'), findsOneWidget);
  });

  testWidgets('未知国家码 → 回退显示码本身', (t) async {
    await _pump(
      t,
      const NetworkDetectionState(
        isLoading: false,
        ipInfo: IpInfo(ip: '1.2.3.4', countryCode: 'ZZ'),
      ),
    );
    expect(find.text('出口 IP (ZZ)'), findsOneWidget);
  });
}
