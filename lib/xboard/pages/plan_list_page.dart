/// R8 套餐列表页：瘦身卡片（名 + 摘要 + 最小周期价 + 箭头）→ 点进套餐详情页。
///
/// **数据源**：反腐层 `getPlans()`。卡片只显示概要；周期选择 / 优惠码 / 提交在 [PlanDetailPage]。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_theme.dart' show xbPush;
import '../models/plan_item.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/error_text.dart';
import '../util/html_text.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'plan_detail_page.dart';

class PlanListPage extends ConsumerStatefulWidget {
  const PlanListPage({super.key});

  @override
  ConsumerState<PlanListPage> createState() => _PlanListPageState();
}

class _PlanListPageState extends ConsumerState<PlanListPage> {
  late Future<List<PlanItem>> _plansFuture;

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

  void _reload() => setState(() => _plansFuture = _loadPlans());

  @override
  Widget build(BuildContext context) {
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(builder: _buildScaffold),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('购买套餐')),
      body: FutureBuilder<List<PlanItem>>(
        future: _plansFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            final err = snap.error;
            final msg = err is XbDomainError
                ? resolveErrorText(err, fallback: '加载套餐失败')
                : '加载套餐失败';
            return XbErrorRetry(message: msg, onRetry: _reload);
          }
          final plans = snap.data ?? const <PlanItem>[];
          if (plans.isEmpty) {
            return const Center(child: Text('暂无可购买套餐'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: plans.length,
            itemBuilder: (_, i) => _PlanSummaryCard(
              plan: plans[i],
              onTap: () => xbPush(context, PlanDetailPage(plan: plans[i]),
                  brandColor: Color(XboardConfig.current.brandColor)),
            ),
          );
        },
      ),
    );
  }
}

/// 瘦身套餐卡：名 + 一行摘要（HTML 首段纯文本）+ 最小周期价「¥X/周期 起」+ 箭头。
class _PlanSummaryCard extends StatelessWidget {
  const _PlanSummaryCard({required this.plan, required this.onTap});
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final min = _minPeriodPrice;
    // 摘要：HTML content 转纯文本取首行非空。
    final summary = plan.description == null
        ? ''
        : htmlToPlainText(plan.description!)
            .split('\n')
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(plan.name,
                              style: text.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis),
                        ),
                        XbTag('${plan.transferEnableGb} GB'),
                      ],
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 10),
                    if (min != null)
                      RichText(
                        text: TextSpan(
                          style: text.titleMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w800),
                          children: [
                            TextSpan(
                                text: '¥${min.amountYuan.toStringAsFixed(2)}'),
                            TextSpan(
                              text: '/${planPeriodLabel(min.period)} 起',
                              style: text.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w400),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
