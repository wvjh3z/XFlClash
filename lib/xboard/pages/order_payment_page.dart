/// R9 订单/支付页（pending 与终态共用）：订单状态 + 产品信息 + 订单信息 + 支付方式 + 操作。
///
/// **数据源**：反腐层 `getOrder()` / `getPaymentMethods()` / `checkout()` / `cancelOrder()`。
/// pending → 显示支付方式 + 立即支付/取消订单/检测支付状态 + **自动轮询**（pending/processing
/// 每 5s 拉一次 getOrder，终态停）；终态 → 仅显示信息无操作。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/checkout_outcome_ui.dart';
import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../services/subscription_triggers.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_feedback.dart' show xbToast, xbConfirm, xbBrandColor;
import '../widgets/xb_submit_guard.dart';
import '../widgets/xb_theme.dart' show xbShowDialog, XbTokens;
import '../widgets/xb_async_view.dart';
import '../widgets/xb_ui_kit.dart';

/// 轮询间隔（pending/processing 时）。
const _kPollInterval = Duration(seconds: 5);

class OrderPaymentPage extends ConsumerStatefulWidget {
  const OrderPaymentPage({super.key, required this.tradeNo});
  final String tradeNo;

  @override
  ConsumerState<OrderPaymentPage> createState() => _OrderPaymentPageState();
}

class _OrderPaymentPageState extends ConsumerState<OrderPaymentPage>
    with XbSubmitGuard<OrderPaymentPage> {
  OrderDetail? _detail;
  List<PaymentMethodItem> _methods = const [];
  bool _methodsError = false; // 支付方式加载失败 → 支付方式区显示重试块
  String? _selectedMethodId;
  Object? _loadError;
  bool _loading = true;
  bool _retrying = false; // 重试中 → 顶部「正在刷新服务」黄条
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _initialLoad();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialLoad({bool retry = false}) async {
    setState(() {
      _loading = true;
      _retrying = retry;
    });
    final service = ref.read(xboardServiceProvider);
    try {
      final orderRes = await service.getOrder(widget.tradeNo);
      final detail = switch (orderRes) {
        XbSuccess(:final data) => data,
        XbFailure(:final error) => throw error, // 抛领域错误，_errorRetry 还原文案
      };
      // 支付方式（仅 pending 需要）。失败不阻塞整页（订单信息仍可看），但记录失败态 → 支付方式区显示重试。
      var methods = const <PaymentMethodItem>[];
      var methodsError = false;
      if (detail != null && detail.summary.status == XbOrderStatus.pending) {
        final mRes = await service.getPaymentMethods();
        switch (mRes) {
          case XbSuccess(:final data):
            methods = data;
          case XbFailure():
            methodsError = true;
        }
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _methods = methods;
        _methodsError = methodsError;
        _selectedMethodId = methods.isNotEmpty ? methods.first.id : null;
        _loading = false;
        _retrying = false;
      });
      _maybeStartPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
        _retrying = false;
      });
    }
  }

  /// 仅重拉支付方式（支付方式加载失败重试，#11）：不重载整页订单，只补支付方式区。
  Future<void> _reloadMethods() async {
    await runSubmit(() async {
      final mRes = await ref.read(xboardServiceProvider).getPaymentMethods();
      if (!mounted) return;
      setState(() {
        switch (mRes) {
          case XbSuccess(:final data):
            _methods = data;
            _methodsError = false;
            _selectedMethodId = data.isNotEmpty ? data.first.id : null;
          case XbFailure():
            _methodsError = true;
        }
      });
    });
  }

  /// 静默刷新（轮询 / 检测支付状态用，不显示全屏 loading）。
  Future<void> _refreshStatus() async {
    final service = ref.read(xboardServiceProvider);
    final orderRes = await service.getOrder(widget.tradeNo);
    if (orderRes case XbSuccess(:final data) when data != null && mounted) {
      final wasNonTerminal = _detail != null && !_isTerminal(_detail!.summary.status);
      setState(() => _detail = data);
      // 刚变终态（支付成功 → completed）→ 刷新账号卡 + 订阅同步（T3）+ 停轮询。
      if (wasNonTerminal && _isTerminal(data.summary.status)) {
        SubscriptionTriggers.onOrderCompleted(ref);
        _pollTimer?.cancel();
      }
      _maybeStartPolling();
    }
  }

  void _maybeStartPolling() {
    final status = _detail?.summary.status;
    if (status == null) return;
    final shouldPoll =
        status == XbOrderStatus.pending || status == XbOrderStatus.processing;
    if (shouldPoll && (_pollTimer == null || !_pollTimer!.isActive)) {
      _pollTimer = Timer.periodic(_kPollInterval, (_) => _refreshStatus());
    } else if (!shouldPoll) {
      _pollTimer?.cancel();
    }
  }

  bool _isTerminal(XbOrderStatus s) =>
      s == XbOrderStatus.cancelled ||
      s == XbOrderStatus.completed ||
      s == XbOrderStatus.discounted;

  @override
  Widget build(BuildContext context) {
    return XbBrandTheme(
      brandColor: xbBrandColor(),
      child: Builder(builder: _buildScaffold),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('支付订单')),
      body: XbAsyncView(
        loading: _loading && !_retrying,
        retrying: _retrying,
        error: _loadError,
        errorFallback: '加载订单失败',
        onRetry: () => _initialLoad(retry: true),
        builder: (context) => _detail == null
            ? const Center(child: Text('订单不存在'))
            : _content(context, _detail!),
      ),
    );
  }

  Widget _content(BuildContext context, OrderDetail detail) {
    final s = detail.summary;
    final isPending = s.status == XbOrderStatus.pending;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _StatusCard(status: s.status),
        const SizedBox(height: 16),
        _SectionCard(
          title: '产品信息',
          children: [
            _row('套餐名称', s.planName ?? '套餐订单'),
            _row('周期', planPeriodLabel(s.period)),
          ],
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: '订单信息',
          children: [
            _copyableRow('订单号', s.tradeNo),
            _row('创建时间', _fmtDateTime(s.createdAt)),
            if (detail.balanceAmountYuan != null)
              _row('余额抵扣', '¥${detail.balanceAmountYuan!.toStringAsFixed(2)}'),
            if (detail.discountAmountYuan != null)
              _row('优惠券', '¥${detail.discountAmountYuan!.toStringAsFixed(2)}'),
            if (detail.handlingAmountYuan != null)
              _row('手续费', '¥${detail.handlingAmountYuan!.toStringAsFixed(2)}'),
            _totalRow('含手续费总额', s.totalAmountYuan),
          ],
        ),
        if (isPending) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: '支付方式',
            children: [_paymentMethods(context)],
          ),
          const SizedBox(height: 20),
          _actions(context),
        ],
      ],
    );
  }

  Widget _paymentMethods(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 加载失败 → 小重试块（替代「暂无支付方式」死胡同，原型 17b）。仅重拉支付方式，不动订单。
    if (_methodsError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: [
            Text('支付方式加载失败',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: submitting ? null : _reloadMethods,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重新加载'),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.primary,
                side: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.40), width: 1.6),
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
            ),
          ],
        ),
      );
    }
    if (_methods.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无可用支付方式'),
      );
    }
    final text = Theme.of(context).textTheme;
    return Column(
      children: _methods.map((m) {
        final selected = m.id == _selectedMethodId;
        final feeText = (m.feePercent != null && m.feePercent! > 0)
            ? '手续费: ${m.feePercent!.toStringAsFixed(2)}%'
            : (m.feeFixedYuan != null && m.feeFixedYuan! > 0)
                ? '手续费: ¥${m.feeFixedYuan!.toStringAsFixed(2)}'
                : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: submitting ? null : () => setState(() => _selectedMethodId = m.id),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.08)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? scheme.primary : Colors.transparent,
                  width: 1.6,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name,
                            style: text.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if (feeText != null) ...[
                          const SizedBox(height: 2),
                          Text(feeText,
                              style: text.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _actions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        FilledButton.icon(
          onPressed: submitting ? null : _pay,
          icon: submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: Colors.white))
              : const Icon(Icons.payment_rounded),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            minimumSize: const Size.fromHeight(XbTokens.hButton),
          ),
          label: const Text('立即支付'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: submitting ? null : _cancel,
          icon: const Icon(Icons.close_rounded, size: 18),
          style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(XbTokens.hButton)),
          label: const Text('取消订单'),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: submitting ? null : _refreshStatus,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('检测支付状态'),
        ),
      ],
    );
  }

  Future<void> _pay() async {
    final method = _selectedMethodId ?? '';
    await runSubmit(() async {
      final result =
          await ref.read(xboardServiceProvider).checkout(widget.tradeNo, method);
      if (result case XbFailure(:final error)) {
        _toast('支付失败：${resolveErrorText(error, fallback: '请稍后重试')}');
        return;
      }
      if (!mounted) return;
      await _handleOutcome((result as XbSuccess<CheckoutOutcomeUi>).data);
    });
  }

  Future<void> _handleOutcome(CheckoutOutcomeUi outcome) async {
    switch (outcome) {
      case CheckoutRedirect(:final url):
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          _toast('已打开支付页面，完成后返回点「检测支付状态」');
        } else {
          _toast('无法打开支付页面');
        }
      case CheckoutQrCode(:final qrCodeUrl):
        if (mounted) await _showQrDialog(qrCodeUrl);
      case CheckoutPaid():
        SubscriptionTriggers.onOrderCompleted(ref); // T3：订阅同步 + 账号刷新
        _toast('支付成功');
        await _refreshStatus();
      case CheckoutCanceled(:final message):
        _toast(message ?? '已取消');
      case CheckoutFailed(:final message):
        _toast('支付失败：$message');
    }
  }

  Future<void> _showQrDialog(String qrUrl) async {
    await xbShowDialog<void>(
      context: context,
      brandColor: xbBrandColor(),
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
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    await _refreshStatus(); // 关闭二维码后查最新状态。
  }

  Future<void> _cancel() async {
    final confirm = await xbConfirm(
      context,
      title: '取消订单',
      message: '确定取消这笔订单吗？',
      confirmLabel: '确定取消',
      cancelLabel: '再想想',
      destructive: true,
    );
    if (!confirm) return;
    await runSubmit(() async {
      final result =
          await ref.read(xboardServiceProvider).cancelOrder(widget.tradeNo);
      switch (result) {
        case XbSuccess():
          _toast('订单已取消');
          await _refreshStatus();
        case XbFailure(:final error):
          _toast('取消失败：${resolveErrorText(error, fallback: '请稍后重试')}');
      }
    });
  }

  // ── helpers ──

  Widget _row(String label, String value) => _InfoRow(label: label, value: value);
  Widget _copyableRow(String label, String value) =>
      _CopyableRow(label: label, value: value);
  Widget _totalRow(String label, double yuan) => _TotalRow(label: label, yuan: yuan);

  String _fmtDateTime(DateTime d) => xbDateTime(d);

  void _toast(String msg) {
    if (!mounted) return;
    xbToast(context, msg);
  }
}

/// 订单状态卡（顶部，按状态变色 + 文案）。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});
  final XbOrderStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // 语义色统一取 XbTokens（原型 --warn/--info/--ok/--bad），不再各页硬编码。
    final (icon, title, desc, color) = switch (status) {
      XbOrderStatus.pending => (
          Icons.schedule_rounded,
          '待支付',
          '请选择您的支付方式完成订单',
          XbTokens.warn,
        ),
      XbOrderStatus.processing => (
          Icons.hourglass_top_rounded,
          '处理中',
          '订单正在处理，请稍候…',
          XbTokens.info,
        ),
      XbOrderStatus.completed => (
          Icons.check_circle_rounded,
          '已完成',
          '订单已支付完成',
          XbTokens.ok,
        ),
      XbOrderStatus.discounted => (
          Icons.verified_rounded,
          '已抵扣',
          '订单已通过余额 / 优惠抵扣完成',
          XbTokens.ok,
        ),
      XbOrderStatus.cancelled => (
          Icons.cancel_rounded,
          '已取消',
          '订单已取消',
          XbTokens.bad,
        ),
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 36),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: text.titleMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(desc,
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息分区卡（标题 + 子行）。
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                softWrap: true),
          ),
        ],
      ),
    );
  }
}

class _CopyableRow extends StatelessWidget {
  const _CopyableRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('订单号已复制')),
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(value,
                        textAlign: TextAlign.right,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                        softWrap: true),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.copy_rounded,
                      size: 15, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.yuan});
  final String label;
  final double yuan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          // 行内合计金额：显式 21px（不用 titleLarge=屏幕大标题 24，避免大字号缩放溢出）；
          // 用 Flexible+FittedBox 让超大缩放时金额自适应收缩而非撑破布局。
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text('¥${yuan.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary)),
            ),
          ),
        ],
      ),
    );
  }
}
