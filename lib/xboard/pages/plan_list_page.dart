/// R8 套餐列表页：瘦身卡片（名 + 摘要 + 最小周期价 + 箭头）→ 点进套餐详情页。
///
/// **数据源**：反腐层 `getPlans()`。卡片只显示概要；周期选择 / 优惠码 / 提交在 [PlanDetailPage]。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../models/plan_item.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/format.dart';
import '../util/html_text.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'pending_order_section.dart';
import 'plan_detail_page.dart';

class PlanListPage extends ConsumerStatefulWidget {
  const PlanListPage({super.key});

  @override
  ConsumerState<PlanListPage> createState() => _PlanListPageState();
}

class _PlanListPageState extends ConsumerState<PlanListPage> {
  late Future<List<PlanItem>> _plansFuture;

  /// 重试中（点「重试」后到结果返回前）：顶部显示「正在刷新服务」黄条，告知用户后台在切域名重拉。
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _plansFuture = _loadPlans();
  }

  Future<List<PlanItem>> _loadPlans() async {
    final result = await ref.read(xboardServiceProvider).getPlans();
    return switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw error, // 抛领域错误，error 分支 resolveErrorText 还原文案
    };
  }

  void _reload() {
    setState(() {
      _retrying = true;
      _plansFuture = _loadPlans();
    });
    _plansFuture.whenComplete(() {
      if (mounted) setState(() => _retrying = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return XbBrandScaffold(
      title: '购买套餐',
      body: FutureBuilder<List<PlanItem>>(
        future: _plansFuture,
        builder: (context, snap) {
          final done = snap.connectionState == ConnectionState.done;
          return XbAsyncView(
            loading: !done && !_retrying,
            retrying: _retrying,
            error: done ? snap.error : null,
            errorFallback: '加载套餐失败',
            skeleton: XbSkeletonKind.list,
            onRetry: _reload,
            builder: (context) {
              final plans = snap.data ?? const <PlanItem>[];
              if (plans.isEmpty) {
                return const Center(child: Text('暂无可购买套餐'));
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: plans.length + 2,
                itemBuilder: (_, i) {
                  if (i == 0) return const PendingOrderSection();
                  if (i == 1) return const XbGroupLabel('选择套餐');
                  final plan = plans[i - 2];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: _PlanOptCard(
                      plan: plan,
                      onTap: () => xbPush(context, PlanDetailPage(plan: plan),
                          brandColor: xbBrandColor()),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// 套餐选项卡（原型 `.planopt`）：名 + 流量/特性摘要 + 大号品牌价「¥X/周期 起」+ GB 角标。
class _PlanOptCard extends StatelessWidget {
  const _PlanOptCard({required this.plan, required this.onTap});
  final PlanItem plan;
  final VoidCallback onTap;

  /// 取最小周期价（排除流量重置包；周期 enum 顺序靠前 = 周期更短 = 价更低，取第一个有价的）。
  PricePlan? get _minPeriodPrice {
    final purchasable = plan.prices
        .where((p) => p.period != XbPlanPeriod.resetTraffic)
        .toList();
    if (purchasable.isEmpty) return null;
    purchasable.sort((a, b) => a.period.index.compareTo(b.period.index));
    return purchasable.first;
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final min = _minPeriodPrice;
    // 特性摘要（原型 .ft）：HTML content 转纯文本，取前 3 行非空（用 · 连接，显示更多套餐详情）。
    final feature = plan.description == null
        ? ''
        : htmlToPlainText(plan.description!)
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .take(3)
            .join(' · ');

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(XbTokens.rMd),
          border: Border.all(color: t.line, width: 1.6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(plan.name,
                            style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w600,
                                color: t.on),
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      XbTag('${plan.transferEnableGb} GB'),
                    ],
                  ),
                  if (feature.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(feature,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, height: 1.5, color: t.onv)),
                  ],
                  if (min != null) ...[
                    const SizedBox(height: 10),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: xbYuan(min.amountYuan),
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ]),
                          ),
                          TextSpan(
                            text: ' /${planPeriodLabel(min.period)} 起',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: t.onv),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: t.onv),
          ],
        ),
      ),
    );
  }
}
