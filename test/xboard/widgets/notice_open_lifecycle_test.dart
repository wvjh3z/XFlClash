import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_notice.dart';
import 'package:fl_clash/xboard/providers/notice_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/util/notice_read_store.dart';
import 'package:fl_clash/xboard/widgets/xb_announcement.dart';
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart' show XbHomeSyncNotice;
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';

class _Service extends Mock implements XboardService {}

class _Store extends NoticeReadStore {
  final requests = <Completer<void>>[];
  final owners = <String>[];
  @override
  Future<void> markRead(List<XbNotice> notices, {required String userIdHash}) {
    owners.add(userIdHash);
    final request = Completer<void>();
    requests.add(request);
    return request.future;
  }
}
void main() {
  testWidgets('API 恢复先于公告首读失败，只补读一次且无需手点', (tester) async {
    final service = _Service();
    final slow = Completer<XbResult<List<XbNotice>>>();
    var calls = 0;
    when(service.getNotices).thenAnswer((_) async => ++calls == 1
        ? slow.future : const XbSuccess(<XbNotice>[]));
    final c = ProviderContainer(overrides: [xboardServiceProvider.overrideWithValue(service)]);
    addTearDown(c.dispose);
    c.read(bootstrapReadyProvider.notifier).set(true);
    c.read(authStateProvider.notifier).markAuthenticated();
    await tester.pumpWidget(UncontrolledProviderScope(container: c,
      child: const MaterialApp(home: Scaffold(body: XbNoticePill()))));
    c.read(networkRecoveryProvider.notifier).publish();
    expect(calls, 1);
    slow.complete(const XbFailure(XbNetwork(XbNetworkKind.cancelled, 'network changed')));
    await tester.pumpAndSettle();
    expect(find.text('公告重试'), findsNothing);
    expect(calls, 2);
  });
  testWidgets('公告读取失败显示重试，恢复后的成功空列表才隐藏提示', (tester) async {
    final service = _Service();
    var calls = 0;
    when(service.getNotices).thenAnswer((_) async => ++calls == 1
        ? const XbFailure<List<XbNotice>>(XbNetwork(XbNetworkKind.connectionFailed, 'offline'))
        : const XbSuccess(<XbNotice>[]));
    final container = ProviderContainer(overrides: [xboardServiceProvider.overrideWithValue(service),
      userProfileProvider.overrideWith((_) async => const XbDomainSubscription(email: 'test', uuid: 'fixture', totalBytes: 0, usedBytes: 0))]);
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(authStateProvider.notifier).markAuthenticated();
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: const MaterialApp(home: Scaffold(body: Column(children: [XbNoticePill(), XbHomeSyncNotice()])))));
    await tester.pumpAndSettle();
    expect(find.text('公告暂未更新'), findsOneWidget);
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(find.text('公告暂未更新'), findsNothing);
    expect(find.text('有新公告'), findsNothing);
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
  });
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      for (final mode in ['dispose', 'repeat', 'remount', 'logout-kept']) {
        testWidgets('$brand $platform notice $mode', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = platform == TargetPlatform.android ? const Size(430, 950) : const Size(1000, 950);
          addTearDown(tester.view.reset);
          XboardConfig.bind(XboardConfig(appName: brand, flavorId: brand, subscribeUserAgent: 'fixture', devApiEndpoint: '', devSubscriptionEndpoint: '', debug: true, kIsTest: true, formA: true));
          addTearDown(XboardConfig.resetForTest);
          final store = _Store();
          final visible = ValueNotifier(true);
          addTearDown(visible.dispose);
          var reads = 0;
          var state = XbNoticeState(notices: [XbNotice(id: 1, title: 'fixture notice', content: '<p>fixture body</p>', createdAt: DateTime(2026), updatedAt: 1)], hasUnread: true, userIdHash: 'fixture-owner');
          await tester.pumpWidget(ProviderScope(overrides: [
            noticeReadStoreProvider.overrideWithValue(store),
            noticeStateProvider.overrideWith((ref) async { reads++; return state; }),
          ], child: MaterialApp(theme: ThemeData(platform: platform), home: Scaffold(body: ValueListenableBuilder<bool>(valueListenable: visible, builder: (context, value, _) => value ? const XbNoticePill() : const SizedBox())))));
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(tester.element(find.byType(XbNoticePill)));
          container.read(authStateProvider.notifier).markAuthenticated();
          VoidCallback tapCallback() => tester.widget<GestureDetector>(find.ancestor(of: find.text('有新公告'), matching: find.byType(GestureDetector)).first).onTap!;
          final tap = tapCallback();
          tap();await tester.pump();
          expect(store.requests.length, 1);
          if (mode == 'dispose' || mode == 'remount') {
            visible.value = false;await tester.pumpAndSettle();
          }
          if (mode == 'dispose') {
            store.requests[0].complete();await tester.pumpAndSettle();
            expect(find.text('公告', skipOffstage: false), findsNothing);
          } else if (mode == 'remount') {
            visible.value = true;await tester.pumpAndSettle();
            final newTap = tapCallback();newTap();await tester.pump();
            expect(store.requests.length, 2);
            store.requests[0].complete();await tester.pumpAndSettle();
            newTap();await tester.pump();expect(store.requests.length, 2);
            store.requests[1].complete();await tester.pumpAndSettle();
            expect(find.text('公告', skipOffstage: false), findsOneWidget);
          } else if (mode == 'repeat') {
            tap();tap();await tester.pump();expect(store.requests.length, 1);
            store.requests[0].complete();await tester.pumpAndSettle();
            // Programmatically re-enter while the dialog is still open.
            tap();await tester.pump();expect(store.requests.length, 1);
            expect(find.text('公告', skipOffstage: false), findsOneWidget);
            await tester.tap(find.text('我知道了'));await tester.pumpAndSettle();
            expect(find.text('有新公告'), findsNothing);
            expect(reads, 1, reason: 'marking the loaded snapshot read does not fetch notices');
            state = XbNoticeState(notices: [...state.notices, XbNotice(id: 2, title: 'new',
              content: 'new', createdAt: DateTime(2026), updatedAt: 2)], hasUnread: true, userIdHash: state.userIdHash);
            container.invalidate(noticeStateProvider);
            await tester.pumpAndSettle();
            expect(find.text('有新公告'), findsOneWidget);
          } else {
            // User explicitly deferred the session check; do not change case 2.
            container.read(authStateProvider.notifier).markUnauthenticated();
            state = XbNoticeState.empty;container.invalidate(noticeStateProvider);
            await tester.pumpAndSettle();store.requests[0].complete();await tester.pumpAndSettle();
            expect(find.text('公告'), findsOneWidget);
            expect(store.owners, ['fixture-owner']);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
