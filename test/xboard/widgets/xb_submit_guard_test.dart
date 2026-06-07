/// XbSubmitGuard 行为契约测试（批次二纪律：行为类抽象必须覆盖失败/异常/重入/卸载路径）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_submit_guard.dart';

/// 测试宿主：暴露 runSubmit + submitting，记录每次 build 时的 submitting 值。
class _Host extends StatefulWidget {
  const _Host({required this.onReady});
  final void Function(_HostState) onReady;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with XbSubmitGuard<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady(this));
  }

  @override
  Widget build(BuildContext context) =>
      Text('submitting=$submitting', textDirection: TextDirection.ltr);
}

Future<_HostState> _pump(WidgetTester t) async {
  late _HostState st;
  await t.pumpWidget(_Host(onReady: (s) => st = s));
  await t.pump();
  return st;
}

void main() {
  testWidgets('成功路径：submitting true→false，返回结果', (t) async {
    final st = await _pump(t);
    final gate = Completer<int>();
    final fut = st.runSubmit(() => gate.future);
    await t.pump(); // setState(true)
    expect(st.submitting, isTrue, reason: '进行中应为 true');
    gate.complete(42);
    final r = await fut;
    await t.pump();
    expect(r, 42);
    expect(st.submitting, isFalse, reason: '完成后必复位');
  });

  testWidgets('失败返回路径（action 返回但业务失败）：submitting 复位', (t) async {
    final st = await _pump(t);
    final r = await st.runSubmit(() async => 'failure-result');
    await t.pump();
    expect(r, 'failure-result');
    expect(st.submitting, isFalse);
  });

  testWidgets('异常路径：action 抛 → rethrow 给调用方，但 submitting 仍复位（不卡死）',
      (t) async {
    final st = await _pump(t);
    Object? caught;
    try {
      await st.runSubmit(() async => throw StateError('boom'));
    } catch (e) {
      caught = e;
    }
    await t.pump();
    expect(caught, isA<StateError>(), reason: '异常应 rethrow 给调用方');
    expect(st.submitting, isFalse, reason: '抛异常也必须复位（finally 保证）');
  });

  testWidgets('重入安全：进行中再调直接忽略，不重复发起', (t) async {
    final st = await _pump(t);
    var calls = 0;
    final c1 = Completer<void>();
    // 第一次：挂在 completer 上不结束。
    final f1 = st.runSubmit(() async {
      calls++;
      await c1.future;
    });
    await t.pump();
    expect(st.submitting, isTrue);
    // 第二次：进行中再调 → 立即返回 null，action 不执行。
    final r2 = await st.runSubmit(() async {
      calls++;
      return 'should-not-run';
    });
    expect(r2, isNull, reason: '重入应返回 null');
    expect(calls, 1, reason: 'action 只执行一次');
    // 放行第一次。
    c1.complete();
    await f1;
    await t.pump();
    expect(st.submitting, isFalse);
  });

  testWidgets('卸载安全：State dispose 后 action 完成 → 不 setState 不报错', (t) async {
    final st = await _pump(t);
    final c = Completer<void>();
    final f = st.runSubmit(() async => c.future);
    await t.pump();
    // 卸载宿主（dispose State）。
    await t.pumpWidget(const SizedBox.shrink());
    // action 此刻才完成 → finally 里 mounted=false 不应 setState。
    c.complete();
    await f; // 不抛即通过
    expect(t.takeException(), isNull);
  });
}
