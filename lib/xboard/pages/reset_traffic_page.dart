/// R8 流量重置包购买页：当前套餐流量用尽（≥90%）时，单独购买一次流量重置。
///
/// **数据源**：反腐层 `getPlans()`（取当前 planId 的 resetTraffic 价）+ `createOrder()`。
/// 流量重置包不在常规下单页（plan_detail）出现 —— 仅当账号卡触发（用量 ≥ 90%）时进入。
/// 下单成功（`createOrder(planId, resetTraffic)`）→ 跳 [OrderPaymentPage] 选支付方式。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_theme.dart' show xbPush;
import '../models/plan_item.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/error_text.dart';
import '../widgets/xb_ui_kit.dart';
import 'order_payment_page.dart';

class ResetTrafficPage extends ConsumerStatefulWidget {
  const ResetTrafficPage({super.key, required this.planId, this.planName});

  /// 当前套餐 id（来自 [XbDomainSubscription.planId]）。
  final int planId;

  /// 当前套餐名（仅用于展示，可空）。
  final String? planName;

  @override
  ConsumerState<ResetTrafficPage> createState() => _ResetTrafficPageState();
}

class _ResetTrafficPageState extends ConsumerState<ResetTrafficPage> {
  PlanItem? _plan;
  PricePlan? _resetPrice; // 当前套餐的流量重置包价（period == resetTraffic）
  String? _loadError; // 已解析的错误文案（resolveErrorText）
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await ref.read(xboardServiceProvider).getPlans();
    if (!mounted) return;
    switch (result) {
      case XbSuccess(:final data):
        PlanItem? plan;
        for (final p in data) {
          if (p.id == widget.planId) {
            plan = p;
            break;
          }
        }
        PricePlan? reset;
        if (plan != null) {
          for (final pr in plan.prices) {
            if (pr.period == XbPlanPeriod.resetTraffic) {
              reset = pr;
              break;
            }
          }
        }
        setState(() {
          _plan = plan;
          _resetPrice = reset;
          _loading = false;
        });
      case XbFailure(:final error):
        setState(() {
          _loadError = resolveErrorText(error, fallback: '加载失败');
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(builder: _buildScaffold),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('购买流量重置包')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _errorRetry()
              : _resetPrice == null
                  ? _unavailable(context)
                  : _content(context, _plan!, _resetPrice!),
      bottomNavigationBar: _bottomBar(context),
    );
  }

  Widget _errorRetry() =>
      XbErrorRetry(message: _loadError ?? '加载失败', onRetry: _load);

  /// 当前套餐不提供单独的流量重置包（复用 XbEmptyState）。
  Widget _unavailable(BuildContext context) {
    return XbEmptyState(
      icon: Icons.info_outline_rounded,
      title: '当前套餐不支持单独购买流量重置包',
      description: '你可以前往「购买套餐」续费或升级套餐以恢复流量。',
      actionLabel: '返回',
      onAction: () => Navigator.of(context).pop(),
    );
  }

  Widget _content(BuildContext context, PlanItem plan, PricePlan reset) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        // 说明卡（复用 XbInfoCard）。
        XbInfoCard(
          icon: Icons.refresh_rounded,
          text: '购买后立即重置当前套餐「${widget.planName ?? plan.name}」的已用流量，'
              '恢复至 ${plan.transferEnableGb} GB（套餐到期时间不变）。',
        ),
        const SizedBox(height: 16),
        // 价格卡（复用 XbCard）。
        XbCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('流量重置包',
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('一次性恢复 ${plan.transferEnableGb} GB 流量',
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text('¥${reset.amountYuan.toStringAsFixed(2)}',
                  style: text.titleLarge?.copyWith(
                      color: scheme.primary, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ],
    );
  }

  Widget? _bottomBar(BuildContext context) {
    if (_loading || _loadError != null || _resetPrice == null) return null;
    return XbBottomActionBar(
      primaryLabel: '提交订单',
      primaryIcon: Icons.shopping_cart_checkout_rounded,
      primaryLoading: _submitting,
      onPrimary: _submitOrder,
    );
  }

  Future<void> _submitOrder() async {
    setState(() => _submitting = true);
    try {
      final result = await ref
          .read(xboardServiceProvider)
          .createOrder(widget.planId, XbPlanPeriod.resetTraffic);
      switch (result) {
        case XbSuccess(:final data):
          if (!mounted) return;
          xbPush(
            context,
            OrderPaymentPage(tradeNo: data),
            brandColor: Color(XboardConfig.current.brandColor),
            replace: true,
          );
        case XbFailure(:final error):
          _toast('提交订单失败：${error.message}');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
