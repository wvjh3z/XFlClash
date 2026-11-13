import 'dart:async';
import 'dart:convert';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fakes.dart';

void main() {
  test('default config validation waits 10 seconds without sending to absent Core', () async {
    final transport = FakeDesktopCoreTransport();
    final client = CoreRpcClient(transport);
    final watch = Stopwatch()..start();
    try {
      await expectLater(
        client.invoke(method: CoreMethod.configValidate, arguments: {'path': 'synthetic.yaml'}),
        throwsA(isA<TimeoutException>().having((e) => e.duration, 'duration', const Duration(seconds: 10))),
      );
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 9)));
      expect(transport.sentMessages, isEmpty);
      expect(client.pendingCount, 0);
    } finally {
      await client.close();
      await transport.close();
    }
  });

  test('same validator sends and succeeds once Core connection exists', () async {
    final transport = FakeDesktopCoreTransport.connected();
    final client = CoreRpcClient(transport);
    try {
      final pending = client.invoke(method: CoreMethod.configValidate, arguments: {'path': 'synthetic.yaml'});
      await pumpEventQueue();
      final request = jsonDecode(transport.sentMessages.single) as Map<String, dynamic>;
      expect(request['method'], 'config.validate');
      transport.addJson({'id': request['id'], 'result': null});
      expect(await pending, isNull);
      expect(client.pendingCount, 0);
    } finally {
      await client.close();
      await transport.close();
    }
  });
}
