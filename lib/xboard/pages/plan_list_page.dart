/// R8 套餐列表页：瘦身卡片（名 + 摘要 + 最小周期价 + 箭头）→ 点进套餐详情页。
///
/// **数据源**：反腐层 `getPlans()`。卡片只显示概要；周期选择 / 优惠码 / 提交在 [PlanDetailPage]。
library;

import 'package:fl_clash/widgets/widgets.dart';
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
      title: '购买 / 更改套餐',
      // 桌面套餐卡双列网格（原型屏4 .ngrid）；移动 <1000 不受影响。
      maxContentWidth: 1000,
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
              return LayoutBuilder(
                builder: (context, c) {
                  // 宽内容区（桌面，原型屏4）→ 套餐卡双列网格；窄（移动）→ 单列列表。
                  final twoCol = c.maxWidth >= 700;
                  if (!twoCol) {
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
                            onTap: () => xbPush(context,
                                PlanDetailPage(plan: plan),
                                brandColor: xbBrandColor()),
                          ),
                        );
                      },
                    );
                  }
                  const gap = 12.0;
                  final w = (c.maxWidth - 32 - gap) / 2;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const PendingOrderSection(),
                        const XbGroupLabel('选择套餐'),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final plan in plans)
                              SizedBox(
                                width: w,
                                child: _PlanOptCard(
                                  plan: plan,
                                  onTap: () => xbPush(context,
                                      PlanDetailPage(plan: plan),
                                      brandColor: xbBrandColor()),
                                ),
                              ),
                          ],
                        ),
                      ],
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
    // 只展示 1 行套餐详情摘要：直接取 description 的第一行（内容由后台描述自行控制，
    // 客户端不挑拣）。整行用 XbFitText 完整展示、不省略。
    final descLines = plan.description == null
        ? const <String>[]
        : htmlToPlainText(plan.description!)
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
    final summary =
        descLines.isNotEmpty ? descLines.first : '${plan.transferEnableGb} GB';

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(XbTokens.rMd),
          // 原型 .planopt 边框 1.8px。
          border: Border.all(color: t.line, width: 1.8),
        ),
        // 原型 .planopt：第一行 名+流量徽标(同行) · 第二行 摘要 · 第三行 价格(独占一行)。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：套餐名（占满，过长省略）+ 右侧流量徽标（同行）。
            Row(
              children: [
                Expanded(
                  child: EmojiText(plan.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: t.on)),
                ),
                const SizedBox(width: 8),
                XbTag('${plan.transferEnableGb} GB'),
              ],
            ),
            const SizedBox(height: 7),
            // 第二行：单行套餐详情摘要（完整展示、超宽等比缩、绝不省略，框架 XbFitText）。
            XbFitText(summary,
                style: TextStyle(fontSize: 12, height: 1.5, color: t.onv)),
            if (min != null) ...[
              const SizedBox(height: 8),
              // 第三行：价格独占一行、右对齐（品牌色大字 + 周期单位小字）。
              Align(
                alignment: Alignment.centerRight,
                child: RichText(
                  textAlign: TextAlign.right,
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: xbYuan(min.amountYuan),
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
                            fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      TextSpan(
                        text: ' /${planPeriodLabel(min.period)}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: t.onv),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
