/// 测延迟并发策略：runBatchedConcurrent 并发上限 + 顺序契约。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';

void main() {
  test('并发上限 = concurrency（同时在飞的任务数不超过 10）', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final gates = <Completer<void>>[];

    final items = List.generate(100, (i) => i);
    final fut = runBatchedConcurrent<int>(items, 10, (i) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      final c = Completer<void>();
      gates.add(c);
      await c.future;
      inFlight--;
    });

    // 放行：每次只要有在飞任务就全部放行（模拟逐批完成）。
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

  test('从上到下顺序：第 N 批在第 N-1 批之后才开始', () async {
    final startOrder = <int>[];
    final items = List.generate(25, (i) => i); // 25 个 → 3 批(10/10/5)

    await runBatchedConcurrent<int>(items, 10, (i) async {
      startOrder.add(i);
      // 让出事件循环，模拟异步。
      await Future.delayed(const Duration(milliseconds: 1));
    });

    // 第一批(0..9)必须都在第二批(10..19)任何一个之前开始。
    final firstBatchMaxIdx =
        [for (var i = 0; i < 10; i++) startOrder.indexOf(i)].reduce((a, b) => a > b ? a : b);
    final secondBatchMinIdx =
        [for (var i = 10; i < 20; i++) startOrder.indexOf(i)].reduce((a, b) => a < b ? a : b);
    expect(firstBatchMaxIdx, lessThan(secondBatchMinIdx),
        reason: '第一批应全部先于第二批开始（批间串行、从上到下）');
  });

  test('空列表 → 不抛、立即完成', () async {
    await runBatchedConcurrent<int>([], 10, (_) async {});
  });

  test('concurrency<1 → 退化全串行（每次仅 1 个在飞）', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    await runBatchedConcurrent<int>(List.generate(5, (i) => i), 0, (i) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      await Future.delayed(const Duration(milliseconds: 1));
      inFlight--;
    });
    expect(maxInFlight, 1);
  });
}
