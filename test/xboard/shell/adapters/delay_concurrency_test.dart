/// 测延迟并发策略：runPooledConcurrent 并发上限 + 派发顺序 + 慢节点不阻塞契约。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/util/pooled_concurrent.dart';

void main() {
  test('并发上限 = concurrency（同时在飞的任务数不超过 10）', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final gates = <Completer<void>>[];

    final items = List.generate(100, (i) => i);
    final fut = runPooledConcurrent<int>(items, 10, (i) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      final c = Completer<void>();
      gates.add(c);
      await c.future;
      inFlight--;
    });

    // 放行：每次只要有在飞任务就全部放行（模拟逐个完成、池持续补位）。
    while (gates.length < 100) {
      await Future.delayed(Duration.zero);
      for (final c in List.of(gates)) {
        if (!c.isCompleted) c.complete();
      }
    }
    for (final c in gates) {
      if (!c.isCompleted) c.complete();
    }
    await fut;

    expect(maxInFlight, lessThanOrEqualTo(10),
        reason: '任意时刻在飞任务不应超过并发上限 10');
    expect(maxInFlight, greaterThan(1), reason: '应确实并发，而非全串行');
  });

  test('派发顺序：任务按 items 原始顺序进入并发池', () async {
    final startOrder = <int>[];
    final items = List.generate(25, (i) => i);

    await runPooledConcurrent<int>(items, 10, (i) async {
      startOrder.add(i);
      await Future.delayed(const Duration(milliseconds: 1));
    });

    // 首批进入池的就是前 10 个（0..9），其后元素按序补位。
    final firstTen = startOrder.take(10).toList()..sort();
    expect(firstTen, List.generate(10, (i) => i),
        reason: '并发池首批应派发 items 的前 10 个（按原始顺序取）');
  });

  test('慢节点不阻塞：单个慢任务不拖住后续任务推进', () async {
    final items = List.generate(20, (i) => i);
    var completedBeforeSlow = 0;
    var slowDone = false;

    await runPooledConcurrent<int>(items, 5, (i) async {
      // item 0 = 慢节点；其余很快。
      await Future.delayed(Duration(milliseconds: i == 0 ? 80 : 2));
      if (i == 0) {
        slowDone = true;
      } else if (!slowDone) {
        completedBeforeSlow++;
      }
    });

    // 固定批次下含慢节点那批最多 4 个先完成、随后整体停摆；并发池下慢节点只占 1 槽，
    // 远超 4 个短任务会在它之前完成。
    expect(completedBeforeSlow, greaterThan(10),
        reason: '慢节点不应阻塞后续任务推进');
  });

  test('空列表 → 不抛、立即完成', () async {
    await runPooledConcurrent<int>([], 10, (_) async {});
  });

  test('concurrency<1 → 退化全串行（每次仅 1 个在飞）', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    await runPooledConcurrent<int>(List.generate(5, (i) => i), 0, (i) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      await Future.delayed(const Duration(milliseconds: 1));
      inFlight--;
    });
    expect(maxInFlight, 1);
  });
}
