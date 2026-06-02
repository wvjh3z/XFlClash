/// R8 流量重置包购买页：当前套餐流量用尽（≥90%）时，单独购买一次流量重置。
///
/// **数据源**：反腐层 `getPlans()`（取当前 planId 的 resetTraffic 价）+ `createOrder()`。
/// 流量重置包不在常规下单页（plan_detail）出现 —— 仅当账号卡触发（用量 ≥ 90%）时进入。
/// 下单成功（`createOrder(planId, resetTraffic)`）→ 跳 [OrderPaymentPage] 选支付方式。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
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

  Widget _errorRetry() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _loadError ?? '加载失败',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );

  /// 当前套餐不提供单独的流量重置包。
  Widget _unavailable(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline_rounded,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('当前套餐不支持单独购买流量重置包',
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('你可以前往「购买套餐」续费或升级套餐以恢复流量。',
                textAlign: TextAlign.center,
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, PlanItem plan, PricePlan reset) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        // 说明卡
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(Icons.refresh_rounded, color: scheme.primary, size: 32),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  '购买后立即重置当前套餐「${widget.planName ?? plan.name}」的已用流量，'
                  '恢复至 ${plan.transferEnableGb} GB（套餐到期时间不变）。',
                  style: text.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 价格卡
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerHigh,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
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
        ),
      ],
    );
  }

  Widget? _bottomBar(BuildContext context) {
    if (_loading || _loadError != null || _resetPrice == null) return null;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: _submitting ? null : _submitOrder,
          icon: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: Colors.white))
              : const Icon(Icons.shopping_cart_checkout_rounded),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            minimumSize: const Size.fromHeight(50),
          ),
          label: const Text('提交订单'),
        ),
      ),
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
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => OrderPaymentPage(tradeNo: data),
            ),
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
