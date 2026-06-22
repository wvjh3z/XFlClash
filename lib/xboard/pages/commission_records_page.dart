/// 返佣记录页（form-a · 原型「返佣记录」屏）。
///
/// 从「邀请返佣」页 →「查看返佣记录」push 进入（需登录）。
///
/// **纯流水**：后端 `invite/details` 只返回**已发放成功**的返佣（order_amount / get_amount /
/// created_at），无逐条状态、无被邀请人账号 —— 故每条仅展示「套餐订单返佣 · 时间 · +金额」。
///
/// **数据**：`commissionRecordsProvider`（autoDispose，进页拉、离页回收）。永不抛
/// （XbResult → AsyncError，由 [XbAsyncView] 分流）。
/// **复用框架**：XbBrandScaffold / XbAsyncView(骨架 list) / XbCard / XbEmptyState。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../providers/invite_provider.dart';
import '../util/format.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_theme.dart' show XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;

class CommissionRecordsPage extends ConsumerWidget {
  const CommissionRecordsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const XbBrandScaffold(
      title: '返佣记录',
      body: _RecordsBody(),
    );
  }
}

class _RecordsBody extends ConsumerWidget {
  const _RecordsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(commissionRecordsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(commissionRecordsProvider);
        // 等本次重拉落定再收起转圈；失败吞掉（错误态由 XbAsyncView 接管，不重复弹）。
        await ref
            .read(commissionRecordsProvider.future)
            .catchError((_) => const <XbCommissionRecord>[]);
      },
      child: XbAsyncView(
        loading: async.isLoading,
        error: async.hasError ? async.error : null,
        errorFallback: '加载返佣记录失败',
        skeleton: XbSkeletonKind.list,
        onRetry: () => ref.invalidate(commissionRecordsProvider),
        builder: (context) => _content(context, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, List<XbCommissionRecord> records) {
    if (records.isEmpty) {
      return const XbEmptyState(
        icon: Icons.receipt_long,
        title: '暂无返佣记录',
        description: '邀请好友下载注册并成功购买套餐后，返佣记录会显示在这里。',
      );
    }
    // 纯流水：所有记录串进一张卡（原型一致），行间细分隔线，整卡随页滚动。
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        XbCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < records.length; i++) ...[
                if (i != 0)
                  Divider(
                      height: 1,
                      thickness: 1,
                      color: XbTokens.of(context).hair),
                _RecordRow(record: records[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 单条返佣流水行：绿色 redeem 徽标 + 「套餐订单返佣」+ 时间 + 右侧 +金额（绿）。
class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record});
  final XbCommissionRecord record;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: XbTokens.ok.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.redeem, size: 20, color: XbTokens.ok),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('套餐订单返佣',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.on)),
                const SizedBox(height: 3),
                Text(xbDateMinute(record.createdAt),
                    style: TextStyle(fontSize: 11.5, color: t.onv)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '+${xbYuan(record.getAmountYuan)}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: XbTokens.ok,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
