/// W3.4 + W3.5 — XbModeSegment + ModeInfoSheet 单测。
///
/// 覆盖：仅显示智能/全局（隐藏 direct）/ 当前选中映射 / ⓘ 弹说明 sheet / 游客态 dim。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show PatchClashConfig;
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_mode_segment.dart';

Future<void> pumpSegment(
  WidgetTester tester, {
  required Mode mode,
  required AuthState auth,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        patchClashConfigProvider
            .overrideWithBuild((ref, _) => PatchClashConfig(mode: mode)),
        authStateProvider.overrideWith(() => _FakeAuth(auth)),
      ],
      child: const MaterialApp(home: Scaffold(body: XbModeSegment())),
    ),
  );
  await tester.pump();
}

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

void main() {
  testWidgets('显示智能/全局二选一（不出现直连）', (tester) async {
    await pumpSegment(tester, mode: Mode.rule, auth: AuthState.authenticated);
    expect(find.text('智能'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(find.textContaining('直连'), findsNothing);
  });

  testWidgets('ⓘ → 弹出模式说明 sheet（含智能/全局解释）', (tester) async {
    await pumpSegment(tester, mode: Mode.rule, auth: AuthState.authenticated);
    await tester.tap(find.byIcon(Icons.help_outline));
    await tester.pumpAndSettle();
    expect(find.text('代理模式说明'), findsOneWidget);
    expect(find.textContaining('国内网站与 App 直连'), findsOneWidget);
    expect(find.textContaining('临时开启'), findsOneWidget);
  });

  testWidgets('游客态 dim（Opacity 0.5）', (tester) async {
    await pumpSegment(
        tester, mode: Mode.rule, auth: AuthState.unauthenticated);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('代理模式'), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 0.5);
  });

  testWidgets('已登录态不 dim（Opacity 1.0）', (tester) async {
    await pumpSegment(tester, mode: Mode.rule, auth: AuthState.authenticated);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('代理模式'), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1.0);
  });
}
