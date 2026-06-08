/// 接缝点 #9 形态选择回归（form-a 升级后：formA = 唯一 UI，mobile+desktop 统一）。
///
/// 断言接缝点 #9 逻辑：`formA ? XboardAppShell : child`（无 isMobile gate，option a）。
/// - formA=true → 永远走 XboardAppShell（mobile + desktop 统一）。
/// - formA=false（兜底）→ 走原 child（FlClash 原生 HomePage）。
///
/// 复刻 application.dart 接缝点表达式（不全量启动 Application，避免 Manager 链 / 原生依赖）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart' show CoreStatus, ProxyCardType;
import 'package:fl_clash/models/models.dart' show PatchClashConfig, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import '_net_detection_stub.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

/// 复刻接缝点 #9（option a）：`home: formA ? XboardAppShell() : child`。
class _SeamProbe extends ConsumerWidget {
  const _SeamProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useShell = XboardConfig.current.formA;
    return MaterialApp(
      home: useShell ? const XboardAppShell() : const _FallbackHomePage(),
    );
  }
}

class _FallbackHomePage extends StatelessWidget {
  const _FallbackHomePage();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('FLCLASH_HOMEPAGE')));
}

Future<void> pumpGate(
  WidgetTester tester, {
  required bool formA,
  required bool isMobile,
}) async {
  XboardConfig.bind(XboardConfig(
    subscribeUserAgent: 'x flclash',
    devApiEndpoint: 'https://x',
    devSubscriptionEndpoint: 'https://x',
    debug: false,
    kIsTest: true,
    formA: formA,
  ));
  addTearDown(XboardConfig.resetForTest);
  final container = ProviderContainer(
    overrides: [
      isMobileViewProvider.overrideWith((ref) => isMobile),
      // formA 会挂真 XboardAppShell（含 HomeTab 等），补其依赖的 FlClash + auth provider。
      bootstrapReadyProvider.overrideWith(() => _Ready()),
      authStateProvider.overrideWith(() => _Auth()),
      isStartProvider.overrideWith((ref) => false),
      proxiesTabStateProvider.overrideWith((ref) => const ProxiesTabState(
            groups: [],
            currentGroupName: null,
            proxyCardType: ProxyCardType.expand,
            columns: 2,
          )),
      patchClashConfigProvider
          .overrideWithBuild((ref, _) => const PatchClashConfig()),
      netDetectionOverride(),
    ],
  );
  addTearDown(container.dispose);
  container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const _SeamProbe(),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('formA + mobile → XboardAppShell', (tester) async {
    final original = ErrorWidget.builder;
    await pumpGate(tester, formA: true, isMobile: true);
    expect(find.byType(XboardAppShell), findsOneWidget);
    expect(find.text('FLCLASH_HOMEPAGE'), findsNothing);
    ErrorWidget.builder = original; // shell.initState 装了友好 builder，body 末还原
  });

  testWidgets('formA + desktop → XboardAppShell（option a：desktop 也走形态 A 壳）',
      (tester) async {
    final original = ErrorWidget.builder;
    await pumpGate(tester, formA: true, isMobile: false);
    expect(find.byType(XboardAppShell), findsOneWidget);
    expect(find.text('FLCLASH_HOMEPAGE'), findsNothing);
    ErrorWidget.builder = original;
  });

  testWidgets('formA=false + mobile → FlClash 原生 HomePage（兜底）', (tester) async {
    await pumpGate(tester, formA: false, isMobile: true);
    expect(find.byType(XboardAppShell), findsNothing);
    expect(find.text('FLCLASH_HOMEPAGE'), findsOneWidget);
  });

  testWidgets('formA=false + desktop → FlClash 原生 HomePage（兜底）', (tester) async {
    await pumpGate(tester, formA: false, isMobile: false);
    expect(find.byType(XboardAppShell), findsNothing);
    expect(find.text('FLCLASH_HOMEPAGE'), findsOneWidget);
  });
}
