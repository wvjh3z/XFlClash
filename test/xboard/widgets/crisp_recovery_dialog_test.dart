import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/crisp_chat_driver.dart';
import 'package:fl_clash/xboard/widgets/crisp_recovery_dialog.dart';

void main() {
  for (final action in {
    '重试': CrispRecovery.retry,
    '浏览器打开': CrispRecovery.browser,
    '前往下载': CrispRecovery.runtime,
  }.entries) {
    testWidgets('recovery returns explicit ${action.key} choice', (
      tester,
    ) async {
      CrispRecovery? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('客服'),
              onPressed: () async {
                chosen = await showDialog<CrispRecovery>(
                  context: context,
                  builder: (_) => const CrispRecoveryDialog(
                    failure: CrispChatFailure.webView2Unavailable,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('客服'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action.key));
      await tester.pumpAndSettle();
      expect(chosen, action.value);
    });
  }
  testWidgets(
    'network failure does not ask Linux or macOS to install WebView2',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CrispRecoveryDialog(failure: CrispChatFailure.sessionNotReady),
        ),
      );
      expect(find.text('前往下载'), findsNothing);
      expect(find.textContaining('不会自动'), findsOneWidget);
    },
  );
}
