/// W6.4 — 接缝点 #9 desktop gate 回归（R1.6 / NFR-5.2）。
///
/// 断言接缝点 #9 的形态选择逻辑：`formA && isMobileView` 才走 XboardAppShell；
/// desktop（isMobileView=false）或 formB 走原 HomePage。
///
/// 复刻 application.dart 接缝点表达式（不全量启动 Application，避免 Manager 链 / 原生依赖），
/// 锁定 gate 真值表；真机 desktop 回归由 W6.4 集成在 linux 跑。
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

/// 复刻接缝点 #9：`home: (formA && isMobileView) ? XboardAppShell() : child`。
class _SeamProbe extends ConsumerWidget {
  const _SeamProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useShell =
        XboardConfig.current.formA && ref.watch(isMobileViewProvider);
    return MaterialApp(
      home: useShell ? const XboardAppShell() : const _FakeHomePage(),
    );
  }
}

class _FakeHomePage extends StatelessWidget {
  const _FakeHomePage();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('FORM_B_HOMEPAGE')));
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
      // formA+mobile 会挂真 XboardAppShell（含 HomeTab 等），补其依赖的 FlClash + auth provider。
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
    expect(find.text('FORM_B_HOMEPAGE'), findsNothing);
    ErrorWidget.builder = original; // shell.initState 装了友好 builder，body 末还原
  });

  testWidgets('formA + desktop → 形态 B HomePage（R1.6）', (tester) async {
    await pumpGate(tester, formA: true, isMobile: false);
    expect(find.byType(XboardAppShell), findsNothing);
    expect(find.text('FORM_B_HOMEPAGE'), findsOneWidget);
  });

  testWidgets('formB + mobile → 形态 B HomePage（默认）', (tester) async {
    await pumpGate(tester, formA: false, isMobile: true);
    expect(find.byType(XboardAppShell), findsNothing);
    expect(find.text('FORM_B_HOMEPAGE'), findsOneWidget);
  });

  testWidgets('formB + desktop → 形态 B HomePage', (tester) async {
    await pumpGate(tester, formA: false, isMobile: false);
    expect(find.byType(XboardAppShell), findsNothing);
    expect(find.text('FORM_B_HOMEPAGE'), findsOneWidget);
  });
}
