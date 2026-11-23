import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/widgets/xb_network_read_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a recovery signal does not override authorization or write uncertainty',
    () {
      expect(
        xbIsRecoverableReadError(
          const XbNetwork(XbNetworkKind.timeout, 'offline'),
        ),
        isTrue,
      );
      expect(
        xbIsRecoverableReadError(const XbServer(503, 'unavailable')),
        isTrue,
      );
      for (final error in [
        const XbUnauthorized('signed out'),
        const XbBusiness(XbBusinessKind.generic, 'rejected', null),
        const XbServer(200, 'malformed'),
        const XbUnconfirmed('checkout', 'unknown'),
      ]) {
        expect(xbIsRecoverableReadError(error), isFalse);
      }
    },
  );

  testWidgets(
    'only the visible foreground route consumes new recovery events',
    (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final nav = GlobalKey<NavigatorState>();
      final selected = ValueNotifier(true);
      addTearDown(selected.dispose);
      var reads = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            navigatorKey: nav,
            home: ValueListenableBuilder<bool>(
              valueListenable: selected,
              builder: (_, active, _) => Consumer(
                builder: (context, ref, _) {
                  xbListenForReadRecovery(
                    context,
                    ref,
                    () => reads++,
                    active: active,
                  );
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      final recovery = c.read(networkRecoveryProvider.notifier);
      recovery.publish();
      expect(reads, 1);
      selected.value = false;
      await tester.pump();
      recovery.publish();
      expect(reads, 1);
      selected.value = true;
      await tester.pump();
      nav.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      recovery.publish();
      expect(reads, 1);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      recovery.publish();
      expect(reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      recovery.publish();
      expect(reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
