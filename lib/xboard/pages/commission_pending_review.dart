import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers/invite_provider.dart';
import '../sdk/xboard_service.dart';
import '../util/format.dart';

/// The panel cannot correlate a transfer/withdrawal to an individual write.
/// Review is explicit and read-only; it never clears the session's replay lock.
class CommissionPendingReview extends ConsumerStatefulWidget {
  const CommissionPendingReview({super.key, required this.owner, required this.session});
  final XboardService owner;
  final CommissionSession session;

  @override
  ConsumerState<CommissionPendingReview> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<CommissionPendingReview> {
  bool reading = false;
  String? report;
  bool get current => mounted &&
      ref.read(commissionReadOwnerProvider) == (widget.session, widget.owner);

  Future<void> review() async {
    final session = widget.session;
    if (!current || reading || !session.acquire(reconciliation: true)) return;
    setState(() => reading = true);
    try {
      await session.readersDone;
      if (!current) return;
      final result = await widget.owner.getInviteInfo();
      if (!current) return;
      final rows = await widget.owner.getCommissionRecords(pageSize: commissionRecordsPageSize);
      if (!current) return;
      final balance = result.dataOrNull;
      final list = rows.dataOrNull;
      report = '佣金余额：${balance == null ? '无法核实' : xbYuan(balance.commissionBalanceYuan)}；'
          '近期返佣流水：${list == null || list.isEmpty ? '未取得可核实的流水' : '${list.length} 条'}。';
    } catch (_) {
      report = '暂时无法核实余额和流水，可稍后重新核对。';
    } finally {
      session.release();
      if (current) setState(() => reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(commissionReadOwnerProvider) == (widget.session, widget.owner);
    return AlertDialog(
      scrollable: true,
      title: const Text('核对上次操作'),
      content: Text(!active ? '账号已变化，请关闭。' :
        '${widget.session.pendingOperation}结果尚未确认，金额 ${xbYuan((widget.session.pendingCents ?? 0) / 100)}。'
        '请核对余额与流水，并联系在线客服核实原交易。余额或流水变化不能证明该笔已到账，请勿重复提交。'
        '${report == null ? '' : '\n$report'}'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
        TextButton(onPressed: !active || reading ? null : review,
            child: Text(reading ? '核对中…' : '只读核对余额和流水')),
      ],
    );
  }
}
