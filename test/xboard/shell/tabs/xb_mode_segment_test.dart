/// W3.4 + W3.5 — XbModeSegment + ModeInfoSheet 单测。
///
/// 覆盖：仅显示智能/全局（隐藏 direct）/ 当前选中映射 / ⓘ 弹说明 sheet / 游客态 dim。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show PatchClashConfig;
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_mode_segment.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_mode_adapter.dart';

final _mode = StateProvider<XbMode?>((ref) => XbMode.smart);

class _ModeAdapter extends XbModeAdapter {
  final calls = <XbMode>[];
  @override
  XbMode? currentMode(WidgetRef ref) => ref.watch(_mode);
  @override
  void setMode(WidgetRef ref, XbMode mode) {
    calls.add(mode);
    ref.read(_mode.notifier).state = mode;
  }
}

Future<void> pumpSegment(
  WidgetTester tester, {
  required Mode mode,
  required AuthState auth,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        patchClashConfigProvider.overrideWithBuild(
          (ref, _) => PatchClashConfig(mode: mode),
        ),
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
  for (final reducedMotion in [false, true]) {
    testWidgets('mode thumb slides and reverses without delaying actions, reduced=$reducedMotion', (tester) async {
      final adapter = _ModeAdapter();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          xbModeAdapterProvider.overrideWithValue(adapter),
          authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
        ],
        child: MaterialApp(home: Scaffold(body: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: const SizedBox(width: 320, child: XbModeSegment()),
        ))),
      ));
      final thumb = find.byKey(const ValueKey('xb-mode-indicator'));
      final start = tester.getRect(thumb);
      await tester.tap(find.text('全局'));
      expect(adapter.calls, [XbMode.global]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final middle = tester.getRect(thumb);
      final destination = start.left + start.width + 5;
      expect(middle.left, greaterThan(start.left));
      if (reducedMotion) {
        expect(middle.left, closeTo(destination, .1));
      } else {
        expect(middle.left, lessThan(destination));
      }
      await tester.tap(find.text('智能'));
      expect(adapter.calls, [XbMode.global, XbMode.smart]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(thumb).left, closeTo(start.left, .1));
      final container = ProviderScope.containerOf(tester.element(find.byType(XbModeSegment)));
      container.read(_mode.notifier).state = XbMode.global;
      await tester.pumpAndSettle();
      expect(tester.getRect(thumb).left, closeTo(destination, .1));
      expect(adapter.calls, hasLength(2));
      container.read(_mode.notifier).state = null;
      await tester.pump();
      expect(thumb, findsNothing);
      expect(find.text('模式状态异常，请选择智能或全局'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('unexpected direct is not falsely highlighted as smart', (
    tester,
  ) async {
    await pumpSegment(tester, mode: Mode.direct, auth: AuthState.authenticated);
    expect(find.text('模式状态异常，请选择智能或全局'), findsOneWidget);
    final scheme = Theme.of(
      tester.element(find.byType(XbModeSegment)),
    ).colorScheme;
    for (final label in ['智能', '全局']) {
      expect(
        tester.widget<Text>(find.text(label)).style!.color,
        scheme.onSurfaceVariant,
      );
    }
    expect(find.text('直连'), findsNothing);
  });

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
    await pumpSegment(tester, mode: Mode.rule, auth: AuthState.unauthenticated);
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('代理模式'), matching: find.byType(Opacity))
          .first,
    );
    expect(opacity.opacity, 0.5);
  });

  testWidgets('已登录态不 dim（Opacity 1.0）', (tester) async {
    await pumpSegment(tester, mode: Mode.rule, auth: AuthState.authenticated);
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('代理模式'), matching: find.byType(Opacity))
          .first,
    );
    expect(opacity.opacity, 1.0);
  });
}
