import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/storage/profile_mutation_queue.dart';

void main() {
  test('same-owner writes and cleanup retain FIFO order across generations', () async {
    final queue = ProfileMutationQueue();
    final gate = Completer<void>();
    final order = <String>[];
    final old = queue.run('a', 'owner', () async {
      order.add('old'); await gate.future; throw StateError('old failed');
    });
    final observed = expectLater(old, throwsStateError);
    final cleanup = queue.run('a', 'owner', () async { order.add('cleanup'); });
    final next = queue.run('a', 'owner', () async { order.add('new'); });
    expect(order, ['old']);
    expect(queue.isBusy('a', 'owner'), isTrue);
    await queue.run('b', 'owner', () async { order.add('other brand'); });
    await queue.run('a', 'other', () async { order.add('other owner'); });
    gate.complete();
    await observed; await cleanup; await next;
    expect(order, ['old', 'other brand', 'other owner', 'cleanup', 'new']);
    expect(queue.isBusy('a', 'owner'), isFalse);
    expect(await queue.run('a', 'owner', () async => 7), 7);
  });
}
