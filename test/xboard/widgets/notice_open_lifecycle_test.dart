import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_notice.dart';
import 'package:fl_clash/xboard/providers/notice_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/util/notice_read_store.dart';
import 'package:fl_clash/xboard/widgets/xb_announcement.dart';

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
          var state = XbNoticeState(notices: [XbNotice(id: 1, title: 'fixture notice', content: '<p>fixture body</p>', createdAt: DateTime(2026), updatedAt: 1)], hasUnread: true, userIdHash: 'fixture-owner');
          await tester.pumpWidget(ProviderScope(overrides: [
            noticeReadStoreProvider.overrideWithValue(store),
            noticeStateProvider.overrideWith((ref) async => state),
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
            tapCallback()();await tester.pump();expect(store.requests.length, 2);
            store.requests[1].complete();await tester.pumpAndSettle();
            expect(find.text('公告', skipOffstage: false), findsOneWidget);
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
