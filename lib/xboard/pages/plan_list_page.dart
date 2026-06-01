/// R8 套餐购买页：拉套餐列表 → 选周期 → 下单 → 结算（5 分支）。
///
/// **数据源**：反腐层 `getPlans()` / `createOrder()` / `checkout()` / `getPaymentMethods()`。
/// 结算 5 分支（CheckoutOutcomeUi）：redirect → 跳浏览器；qrCode → 二维码弹窗；paid → 成功；
/// canceled/failed → toast。永不抛（反腐层 XbResult）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/checkout_outcome_ui.dart';
import '../models/plan_item.dart';
import '../models/xb_result.dart';
import '../providers/user_profile_provider.dart';
import '../providers/xboard_providers.dart';
import '../widgets/plan_price_card.dart';

class PlanListPage extends ConsumerStatefulWidget {
  const PlanListPage({super.key});

  @override
  ConsumerState<PlanListPage> createState() => _PlanListPageState();
}

class _PlanListPageState extends ConsumerState<PlanListPage> {
  late Future<List<PlanItem>> _plansFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _plansFuture = _loadPlans();
  }

  Future<List<PlanItem>> _loadPlans() async {
    final result = await ref.read(xboardServiceProvider).getPlans();
    return switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw Exception(error.message),
    };
  }

  void _reload() => setState(() => _plansFuture = _loadPlans());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('购买套餐')),
      body: Stack(
        children: [
          FutureBuilder<List<PlanItem>>(
            future: _plansFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorRetry(
                  message: '加载套餐失败',
                  onRetry: _reload,
                );
              }
              final plans = snap.data ?? const <PlanItem>[];
              if (plans.isEmpty) {
                return const Center(child: Text('暂无可购买套餐'));
              }
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: plans.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: PlanPriceCard(
                    plan: plans[i],
                    onSelectPeriod: _busy
                        ? null
                        : (price) => _purchase(plans[i], price),
                  ),
                ),
              );
            },
          ),
          if (_busy)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  /// 下单 + 结算（createOrder → checkout）。
  Future<void> _purchase(PlanItem plan, PricePlan price) async {
    setState(() => _busy = true);
    try {
      final service = ref.read(xboardServiceProvider);
      // 1. 创建订单。
      final orderResult = await service.createOrder(plan.id, price.period);
      if (orderResult case XbFailure(:final error)) {
        _toast('下单失败：${error.message}');
        return;
      }
      final tradeNo = (orderResult as XbSuccess<String>).data;

      // 2. 选支付方式（取第一个可用；零金额场景 method 可空）。
      final methodsResult = await service.getPaymentMethods();
      final method = switch (methodsResult) {
        XbSuccess(:final data) when data.isNotEmpty => data.first.id,
        _ => '',
      };

      // 3. 结算。
      final checkoutResult = await service.checkout(tradeNo, method);
      if (checkoutResult case XbFailure(:final error)) {
        _toast('结算失败：${error.message}');
        return;
      }
      if (!mounted) return;
      await _handleOutcome((checkoutResult as XbSuccess<CheckoutOutcomeUi>).data);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleOutcome(CheckoutOutcomeUi outcome) async {
    switch (outcome) {
      case CheckoutRedirect(:final url):
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          _toast('无法打开支付页面');
        }
      case CheckoutQrCode(:final qrCodeUrl):
        if (mounted) await _showQrDialog(qrCodeUrl);
      case CheckoutPaid():
        ref.invalidate(userProfileProvider); // 刷新账号卡（流量/到期更新）。
        _toast('支付成功');
        if (mounted) Navigator.of(context).pop();
      case CheckoutCanceled(:final message):
        _toast(message ?? '已取消');
      case CheckoutFailed(:final message):
        _toast('支付失败：$message');
    }
  }

  Future<void> _showQrDialog(String qrUrl) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('扫码支付'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: qrUrl, size: 220),
            const SizedBox(height: 12),
            const Text('请用支付宝 / 微信扫描二维码完成支付',
                textAlign: TextAlign.center),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('支付完成 / 关闭'),
          ),
        ],
      ),
    );
    // 关闭二维码后刷新账号信息（用户可能已支付）。
    ref.invalidate(userProfileProvider);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 40),
          const SizedBox(height: 8),
          Text(message),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
