/// 并发池执行原语（通用工具，§1.5 逻辑放对层：与节点无关，从 xb_nodes_adapter 下沉到 util）。
///
/// 按 [items] 原始顺序取任务，**始终保持最多 [concurrency] 个在跑**——任一任务完成立刻补
/// 下一个进来（滑动窗口），而非固定批次「批内并发、批间串行」。
///
/// **相比固定批次的优势**：固定批次下一批要等上批最慢任务才开始，单个卡住的任务会阻塞后续
/// 整批；并发池下慢任务只占 1 个槽，其余槽继续推进，整体不被个别慢任务拖死。
/// [task] 对单个元素执行异步操作（不应抛；如抛会中断整体）。[concurrency] ≤0 时按 1 处理（全串行）。
library;

import 'dart:async';

Future<void> runPooledConcurrent<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) task,
) async {
  final limit = concurrency < 1 ? 1 : concurrency;
  var next = 0; // 下一个待派发的任务下标。
  final active = <Future<void>>{};

  void spawn() {
    final i = next++;
    late final Future<void> f;
    f = task(items[i]).whenComplete(() => active.remove(f));
    active.add(f);
  }

  // 先填满并发池。
  while (next < items.length && active.length < limit) {
    spawn();
  }
  // 任一完成 → 立刻补一个，保持池满，直至全部派发并跑完。
  while (active.isNotEmpty) {
    await Future.any(active);
    while (next < items.length && active.length < limit) {
      spawn();
    }
  }
}
