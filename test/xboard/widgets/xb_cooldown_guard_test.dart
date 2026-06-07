/// XbCooldownGuard 行为契约测试（批次二纪律：行为类抽象必须覆盖重入/解锁/卸载路径）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_cooldown_guard.dart';

class _Host extends StatefulWidget {
  const _Host({required this.onReady});
  final void Function(_HostState) onReady;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with XbCooldownGuard<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady(this));
  }

  @override
  Widget build(BuildContext context) =>
      Text('cd=$cooldownSeconds', textDirection: TextDirection.ltr);
}

Future<_HostState> _pump(WidgetTester t) async {
  late _HostState st;
  await t.pumpWidget(_Host(onReady: (s) => st = s));
  await t.pump();
  return st;
}

void main() {
  testWidgets('倒计时：startCooldown(3) → 每秒 -1 到 0 自动停', (t) async {
    final st = await _pump(t);
    st.startCooldown(3);
    await t.pump();
    expect(st.cooldownSeconds, 3);
    expect(st.cooling, isTrue);
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 2);
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 1);
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 0);
    expect(st.cooling, isFalse);
    // 再 pump 一秒，不应变成负数（timer 已 cancel）。
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 0);
  });

  testWidgets('重入安全：冷却中再调 startCooldown → 取消旧 timer 重新计时，不叠加双递减',
      (t) async {
    final st = await _pump(t);
    st.startCooldown(5);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 4);
    // 重新启动 10s。
    st.startCooldown(10);
    await t.pump();
    expect(st.cooldownSeconds, 10);
    // 一秒只 -1（若叠加双 timer 会 -2）。
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 9, reason: '不应叠加双 timer 导致一秒 -2');
  });

  testWidgets('立即解锁：resetCooldown 取消 timer 并归零', (t) async {
    final st = await _pump(t);
    st.startCooldown(60);
    await t.pump();
    expect(st.cooldownSeconds, 60);
    st.resetCooldown();
    await t.pump();
    expect(st.cooldownSeconds, 0);
    expect(st.cooling, isFalse);
    // 归零后 timer 已停，再 pump 不复活。
    await t.pump(const Duration(seconds: 1));
    expect(st.cooldownSeconds, 0);
  });

  testWidgets('卸载安全：冷却中 dispose → timer 回调不 setState 不报错，无泄漏', (t) async {
    final st = await _pump(t);
    st.startCooldown(60);
    await t.pump();
    // 卸载宿主。
    await t.pumpWidget(const SizedBox.shrink());
    // timer 本应在 dispose 被 cancel；推进时间确认不报错。
    await t.pump(const Duration(seconds: 2));
    expect(t.takeException(), isNull);
  });
}
