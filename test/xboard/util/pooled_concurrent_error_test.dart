import 'dart:async';

import 'package:fl_clash/xboard/util/pooled_concurrent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'asynchronous failure reaches caller once and later active failure is handled',
    () async {
      final gates = List.generate(2, (_) => Completer<void>());
      final starts = <int>[];
      final error = StateError('first');
      final pool = runPooledConcurrent([0, 1, 2], 2, (i) {
        starts.add(i);
        return gates[i].future;
      });
      final observed = expectLater(pool, throwsA(same(error)));
      await Future<void>.delayed(Duration.zero);
      gates[0].completeError(error);
      await observed;
      gates[1].completeError(StateError('late'));
      await Future<void>.delayed(Duration.zero);
      expect(starts, [0, 1]);
    },
  );
  test(
    'synchronous task throw does not leave an earlier task unobserved',
    () async {
      final active = Completer<void>();
      final error = StateError('synchronous');
      final starts = <int>[];
      final pool = runPooledConcurrent([0, 1, 2], 2, (i) {
        starts.add(i);
        if (i == 1) throw error;
        return active.future;
      });
      await expectLater(pool, throwsA(same(error)));
      active.completeError(StateError('late active failure'));
      await Future<void>.delayed(Duration.zero);
      expect(starts, [0, 1]);
    },
  );
  test(
    'synchronous completed futures do not race the active-set handle',
    () async {
      final starts = <int>[];
      await runPooledConcurrent([0, 1, 2], 2, (i) {
        starts.add(i);
        return SynchronousFuture<void>(null);
      });
      expect(starts, [0, 1, 2]);
    },
  );
}
