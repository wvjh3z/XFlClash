/// R8 套餐列表页：名称 + 最多三行介绍 + 右侧居中周期价 → 套餐详情页。
///
/// **数据源**：反腐层 `getPlans()`。卡片只显示概要；周期选择 / 优惠码 / 提交在 [PlanDetailPage]。
library;

import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:material_ui/material_ui.dart';
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
      XbFailure(:final error) =>
        throw error, // 抛领域错误，error 分支 resolveErrorText 还原文案
    };
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final request = _loadPlans();
    setState(() {
      _retrying = true;
      _plansFuture = request;
    });
    try {
      await request;
    } catch (_) {
      // FutureBuilder retains the original error for the page's retry UI.
      // This completion Future only drives refresh state; it must not leak it.
    } finally {
      if (mounted && identical(_plansFuture, request)) {
        setState(() => _retrying = false);
      }
    }
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
                            onTap: () => xbPush(
                              context,
                              PlanDetailPage(plan: plan),
                              brandColor: xbBrandColor(),
                            ),
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
                                  onTap: () => xbPush(
                                    context,
                                    PlanDetailPage(plan: plan),
                                    brandColor: xbBrandColor(),
                                  ),
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

/// 套餐选项卡：不额外展示流量标记，介绍最多三个显示行，价格独立居中。
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
    // One text layout caps wrapped lines as well as explicit HTML line breaks.
    final description = plan.description == null
        ? ''
        : htmlToPlainText(plan.description!)
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .join('\n');

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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  XbEmojiText(
                    plan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: t.on,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    XbEmojiText(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.clip,
                      style: TextStyle(fontSize: 12, height: 1.5, color: t.onv),
                    ),
                  ],
                ],
              ),
            ),
            if (min != null) ...[
              const SizedBox(width: 12),
              // 价格（原型 .pr）：品牌色大字 + 周期单位小字（底部对齐，无「起」）。
              RichText(
                textAlign: TextAlign.right,
                textScaler: MediaQuery.textScalerOf(context),
                text: TextSpan(
                  style: DefaultTextStyle.of(context).style,
                  children: [
                    TextSpan(
                      text: xbYuan(min.amountYuan),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    TextSpan(
                      text: ' /${planPeriodLabel(min.period)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: t.onv,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
