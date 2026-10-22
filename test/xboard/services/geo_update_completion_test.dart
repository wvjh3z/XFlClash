import 'dart:async';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/services/xb_geo_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void emit(String type, {bool updating = false, String? error}) {
  CoreEventManager.instance.sendEvent(
    CoreEvent(
      type: CoreEventType.geoUpdate,
      data: {'type': type, 'updating': updating, 'error': error},
    ),
  );
}

void main() {
  testWidgets(
    'acknowledgement and another resource cannot complete the update',
    (tester) async {
      var done = false;
      final operation = updateXbGeoResource('GEOIP', request: (_) async => '')
          .then((value) {
            done = true;
            return value;
          });
      await tester.pump();
      expect(done, isFalse);
      emit('GEOSITE');
      emit('GEOIP', updating: true);
      await tester.pump();
      expect(done, isFalse);
      emit('geoip');
      await tester.pump();
      expect(await operation, '');
      expect(CoreEventManager.instance.hasListeners, isFalse);
    },
  );

  testWidgets('terminal errors and request failures remain failures', (
    tester,
  ) async {
    final result = updateXbGeoResource('MMDB', request: (_) async => '');
    emit('MMDB', error: 'download failed');
    await tester.pump();
    expect(await result, 'download failed');
    expect(
      await updateXbGeoResource('MMDB', request: (_) async => 'busy'),
      'busy',
    );
    await expectLater(
      updateXbGeoResource(
        'MMDB',
        request: (_) async => throw StateError('offline'),
      ),
      throwsStateError,
    );
    expect(CoreEventManager.instance.hasListeners, isFalse);
  });

  testWidgets('timeout bounds acknowledgement too and removes the listener', (
    tester,
  ) async {
    final ack = Completer<String>();
    final result = updateXbGeoResource(
      'ASN',
      request: (_) => ack.future,
      timeout: const Duration(seconds: 2),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(await result, 'GEO update timed out');
    expect(CoreEventManager.instance.hasListeners, isFalse);
    ack.complete('');
    emit('ASN');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a core crash releases the pending update', (tester) async {
    final result = updateXbGeoResource('GEOIP', request: (_) async => '');
    CoreEventManager.instance.sendEvent(
      const CoreEvent(type: CoreEventType.crash, data: 'stopped'),
    );
    await tester.pump();
    expect(await result, 'Core stopped during GEO update');
    expect(CoreEventManager.instance.hasListeners, isFalse);
  });
}
