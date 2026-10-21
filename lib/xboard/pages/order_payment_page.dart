/// R9 订单/支付页（pending 与终态共用）：订单状态 + 产品信息 + 订单信息 + 支付方式 + 操作。
///
/// **数据源**：反腐层 `getOrder()` / `getPaymentMethods()` / `checkout()` / `cancelOrder()`。
/// pending → 显示支付方式 + 立即支付/取消订单/检测支付状态 + **自动轮询**（pending/processing
/// 每 5s 拉一次 getOrder，终态停）；终态 → 仅显示信息无操作。
library;

import 'dart:async';

import 'package:fl_clash/widgets/widgets.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/checkout_outcome_ui.dart';
import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../providers/auth_state_provider.dart';
import '../providers/xboard_providers.dart';
import '../providers/user_profile_provider.dart';
import '../services/subscription_triggers.dart';
import '../sdk/xboard_service.dart';
import '../shell/widgets/xb_responsive.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_feedback.dart' show xbConfirm, xbBrandColor, XbStateToast;
import '../widgets/xb_center_toast.dart';
import '../widgets/xb_motion.dart';
import '../widgets/xb_submit_guard.dart';
import '../widgets/xb_theme.dart' show xbShowDialog, XbTokens;
import '../widgets/xb_async_view.dart';
import '../widgets/xb_ui_kit.dart';
import '../widgets/xb_emoji_text.dart';

/// 轮询间隔（pending/processing 时）。
const _kPollInterval = Duration(seconds: 5);

typedef _OrderRead = ({
  XbResult<OrderDetail?> result,
  int contextVersion,
  int readVersion,
  String tradeNo,
  XboardService service,
});

class OrderPaymentPage extends ConsumerStatefulWidget {
  const OrderPaymentPage({super.key, required this.tradeNo});
  final String tradeNo;

  @override
  ConsumerState<OrderPaymentPage> createState() => _OrderPaymentPageState();
}

class _OrderPaymentPageState extends ConsumerState<OrderPaymentPage>
    with XbSubmitGuard<OrderPaymentPage>, WidgetsBindingObserver {
  OrderDetail? _detail;
  List<PaymentMethodItem> _methods = const [];
  bool _methodsError = false; // 支付方式加载失败 → 支付方式区显示重试块
  String? _selectedMethodId;
  Object? _loadError;
  bool _loading = true;
  bool _retrying = false; // 重试中 → 顶部「正在刷新服务」黄条
  Timer? _pollTimer;
  Future<_OrderRead>? _orderRead;
  int _contextVersion = 0;
  int _readVersion = 0;
  int _loadAttempt = 0;
  bool _checking = false;
  bool _checkFailed = false;
  bool _completionTriggered = false;
  bool _qrVisible = false;
  bool _foreground = true;
  ProviderSubscription<AuthState>? _authSubscription;
  ProviderSubscription<XboardService>? _serviceSubscription;
  VoidCallback? _dismissFeedback;

  bool get _actionsBusy => submitting || _checking || _loading;

  /// 依赖变化时更新缓存，dispose 时不再查询已 deactivated 的 context。
  late ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _authSubscription = ref.listenManual(authStateProvider, (previous, next) {
      if (previous == next) return;
      _resetContext(error: const XbUnauthorized('登录状态已变化，请重新打开订单。'));
    });
    _serviceSubscription = ref.listenManual(xboardServiceProvider, (
      previous,
      next,
    ) {
      if (identical(previous, next)) return;
      _resetContext();
      unawaited(_initialLoad());
    });
    unawaited(_initialLoad());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    ++_contextVersion;
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.close();
    _serviceSubscription?.close();
    _pollTimer?.cancel();
    _dismissFeedback?.call();
    // 缺口 1 兜底：用户从支付页 pop 回 Tab 时 invalidate userProfileProvider,
    // 确保三张卡(账号卡/到期卡/流量卡)最终刷新。幂等(多一次 getSubscription 无害)。
    _container.invalidate(userProfileProvider);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OrderPaymentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tradeNo != widget.tradeNo) {
      _resetContext();
      unawaited(_initialLoad());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _pollTimer?.cancel();
      _dismissFeedback?.call();
      return;
    }
    if (_detail != null && !_isTerminal(_detail!.summary.status)) {
      if (!submitting || _qrVisible) unawaited(_refreshStatus());
      _maybeStartPolling();
    }
  }

  void _resetContext({Object? error}) {
    ++_contextVersion;
    ++_readVersion;
    ++_loadAttempt;
    _orderRead = null;
    _pollTimer?.cancel();
    _dismissFeedback?.call();
    setState(() {
      _detail = null;
      _methods = const [];
      _methodsError = false;
      _selectedMethodId = null;
      _loadError = error;
      _loading = false;
      _retrying = false;
      _checking = false;
      _checkFailed = false;
      _completionTriggered = false;
      _qrVisible = false;
    });
  }

  bool _isCurrentRead(_OrderRead read) =>
      mounted &&
      read.contextVersion == _contextVersion &&
      read.readVersion == _readVersion &&
      read.tradeNo == widget.tradeNo &&
      identical(read.service, ref.read(xboardServiceProvider));

  /// 初次加载、手动检测和自动轮询共用一笔在途详情请求。
  Future<_OrderRead> _readOrder() {
    final existing = _orderRead;
    if (existing != null) return existing;
    final contextVersion = _contextVersion;
    final readVersion = _readVersion;
    final tradeNo = widget.tradeNo;
    final service = ref.read(xboardServiceProvider);
    late final Future<_OrderRead> request;
    request = (() async {
      XbResult<OrderDetail?> result;
      try {
        result = await service.getOrder(tradeNo);
        if (result case XbSuccess(
          :final data,
        ) when data != null && data.summary.tradeNo != tradeNo) {
          result = XbResult<OrderDetail?>.failure(
            const XbUnexpected('getOrder', '订单信息不匹配，请重新检测。'),
          );
        }
      } catch (_) {
        result = XbResult<OrderDetail?>.failure(
          const XbUnexpected('getOrder', '暂未获取到订单信息，请稍后重试。'),
        );
      }
      return (
        result: result,
        contextVersion: contextVersion,
        readVersion: readVersion,
        tradeNo: tradeNo,
        service: service,
      );
    })().whenComplete(() {
      if (identical(_orderRead, request)) _orderRead = null;
    });
    // Store and return the cleanup chain itself; do not fork an unobserved Future.
    _orderRead = request;
    return request;
  }

  /// 开通中和终态不能被较旧的待支付响应降级。
  OrderDetail _acceptedDetail(OrderDetail next) {
    final current = _detail;
    if (current == null) return next;
    final oldStatus = current.summary.status;
    final newStatus = next.summary.status;
    if ((_isTerminal(oldStatus) && !_isTerminal(newStatus)) ||
        (oldStatus == XbOrderStatus.processing &&
            newStatus == XbOrderStatus.pending)) {
      return current;
    }
    return next;
  }

  void _observeCompletion() {
    final status = _detail?.summary.status;
    if (_completionTriggered ||
        (status != XbOrderStatus.completed &&
            status != XbOrderStatus.discounted)) {
      return;
    }
    _completionTriggered = true;
    SubscriptionTriggers.onOrderCompleted(ref);
  }

  Future<void> _initialLoad({bool retry = false}) async {
    final attempt = ++_loadAttempt;
    setState(() {
      _loading = true;
      _retrying = retry;
      _loadError = null;
    });
    try {
      final service = ref.read(xboardServiceProvider);
      final read = await _readOrder();
      if (!_isCurrentRead(read) || attempt != _loadAttempt) return;
      final detail = switch (read.result) {
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
      if (!_isCurrentRead(read) || attempt != _loadAttempt) return;
      setState(() {
        _detail = detail == null ? null : _acceptedDetail(detail);
        _methods = methods;
        _methodsError = methodsError;
        _selectedMethodId = methods.isNotEmpty ? methods.first.id : null;
        _loading = false;
        _retrying = false;
        _loadError = null;
        _checkFailed = false;
      });
      _observeCompletion();
      _maybeStartPolling();
    } catch (e) {
      if (!mounted || attempt != _loadAttempt) return;
      setState(() {
        _loadError = e;
        _loading = false;
        _retrying = false;
      });
    }
  }

  /// 仅重拉支付方式（支付方式加载失败重试，#11）：不重载整页订单，只补支付方式区。
  Future<void> _reloadMethods() async {
    if (_actionsBusy) return;
    final owner = _contextVersion;
    await runSubmit(() async {
      final mRes = await ref.read(xboardServiceProvider).getPaymentMethods();
      if (!mounted || owner != _contextVersion) return;
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
  Future<XbResult<OrderDetail?>?> _refreshStatus() async {
    final owner = _contextVersion;
    try {
      final read = await _readOrder();
      if (!_isCurrentRead(read)) return null;
      if (read.result case XbSuccess(:final data) when data != null) {
        setState(() {
          _detail = _acceptedDetail(data);
          _checkFailed = false;
        });
        _observeCompletion();
        _maybeStartPolling();
        return XbResult.success(_detail);
      }
      if (read.result case XbFailure()) return read.result;
      return XbResult<OrderDetail?>.failure(
        const XbUnexpected('getOrder', '暂未获取到最新订单状态。'),
      );
    } catch (_) {
      if (!mounted || owner != _contextVersion) return null;
      return XbResult<OrderDetail?>.failure(
        const XbUnexpected('getOrder', '暂未获取到最新订单状态。'),
      );
    }
  }

  /// 提交操作完成后，丢弃操作前的响应，等待它结束再查最新状态。
  Future<XbResult<OrderDetail?>?> _refreshAfterMutation() async {
    final owner = _contextVersion;
    ++_readVersion;
    final previous = _orderRead;
    if (previous != null) await previous;
    if (!mounted || owner != _contextVersion) return null;
    return _refreshStatus();
  }

  Future<void> _checkStatus() async {
    if (_actionsBusy) return;
    final owner = _contextVersion;
    _dismissFeedback?.call();
    setState(() {
      _checking = true;
      _checkFailed = false;
    });
    final result = await _refreshStatus();
    if (!mounted || owner != _contextVersion) return;
    setState(() {
      _checking = false;
      _checkFailed = result is XbFailure;
    });
    if (result != null) _showCheckFeedback(result);
  }

  void _showCheckFeedback(XbResult<OrderDetail?> result) {
    if (!mounted || !_foreground) return;
    final (title, message, tone, icon) = switch (result) {
      XbFailure(:final error) => (
        '检测失败',
        error is XbNetwork
            ? '请检查网络后重新检测。'
            : error is XbUnauthorized
            ? '登录已失效，请重新登录。'
            : '暂未获取到最新状态，请稍后重新检测。',
        XbToastTone.error,
        Icons.cloud_off_rounded,
      ),
      XbSuccess(:final data) => switch (data!.summary.status) {
        XbOrderStatus.pending => (
          '订单仍待支付',
          '若已完成付款，请稍后再试。',
          XbToastTone.warning,
          Icons.schedule_rounded,
        ),
        XbOrderStatus.processing => (
          '开通中',
          '付款已确认，正在开通服务，请勿重复支付。',
          XbToastTone.info,
          Icons.hourglass_top_rounded,
        ),
        XbOrderStatus.completed => (
          '支付成功',
          '正在刷新套餐与节点信息。',
          XbToastTone.success,
          Icons.check_circle_rounded,
        ),
        XbOrderStatus.discounted => (
          '订单已折抵',
          '正在刷新套餐与节点信息。',
          XbToastTone.success,
          Icons.verified_rounded,
        ),
        XbOrderStatus.cancelled => (
          '订单已取消',
          '如需购买，请重新创建订单。',
          XbToastTone.neutral,
          Icons.cancel_rounded,
        ),
      },
    };
    _dismissFeedback = XbCenterToast.show(
      context,
      message,
      title: title,
      tone: tone,
      icon: icon,
      duration: const Duration(seconds: 4),
    );
  }

  void _maybeStartPolling() {
    final status = _detail?.summary.status;
    if (status == null) return;
    final shouldPoll =
        _foreground &&
        (status == XbOrderStatus.pending || status == XbOrderStatus.processing);
    if (shouldPoll && (_pollTimer == null || !_pollTimer!.isActive)) {
      _pollTimer = Timer.periodic(_kPollInterval, (_) {
        if (!_loading &&
            (!submitting || _qrVisible) &&
            !_checking &&
            _orderRead == null) {
          unawaited(_refreshStatus());
        }
      });
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
    // 按页面实际可用宽度排布，桌面侧栏与嵌套 Navigator 已占用的空间不参与双栏判断。
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = xbIsDesktopWidth(constraints.maxWidth);
        return XbBrandScaffold(
          title: '订单详情',
          maxContentWidth: wide ? 1000 : null,
          body: XbAsyncView(
            loading: _loading && !_retrying,
            retrying: _retrying,
            error: _loadError,
            errorFallback: '加载订单失败',
            onRetry: () => _initialLoad(retry: true),
            builder: (context) => _detail == null
                ? const Center(child: Text('订单不存在'))
                : _content(context, _detail!, wide),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context, OrderDetail detail, bool wide) {
    final s = detail.summary;
    final isPending = s.status == XbOrderStatus.pending;
    final canCheck = !_isTerminal(s.status);
    final statusCard = _StatusCard(status: s.status);
    final productCard = _SectionCard(
      title: '产品信息',
      children: [
        _row('套餐名称', s.planName ?? '套餐订单'),
        _row('周期', planPeriodLabel(s.period)),
      ],
    );
    final orderCard = _SectionCard(
      title: '订单信息',
      children: [
        _copyableRow('订单号', s.tradeNo),
        _row('创建时间', _fmtDateTime(s.createdAt)),
        if (detail.balanceAmountYuan != null)
          _row('余额抵扣', xbYuan(detail.balanceAmountYuan!)),
        if (detail.discountAmountYuan != null)
          _row('优惠券', xbYuan(detail.discountAmountYuan!)),
        if (detail.handlingAmountYuan != null)
          _row('手续费', xbYuan(detail.handlingAmountYuan!)),
        _totalRow('含手续费总额', s.totalAmountYuan),
      ],
    );

    if (wide) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 21,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  statusCard,
                  const SizedBox(height: 16),
                  productCard,
                  const SizedBox(height: 16),
                  orderCard,
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 19,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isPending) ...[
                    _SectionCard(
                      title: '支付方式',
                      children: [_paymentMethods(context)],
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (canCheck) _actions(context),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 手机：单列。开通中仍可检测，但不能重复支付或取消。
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        statusCard,
        const SizedBox(height: 16),
        productCard,
        const SizedBox(height: 16),
        orderCard,
        if (isPending) ...[
          const SizedBox(height: 16),
          _SectionCard(title: '支付方式', children: [_paymentMethods(context)]),
        ],
        if (canCheck) ...[const SizedBox(height: 20), _actions(context)],
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
            Text(
              '支付方式加载失败',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _actionsBusy ? null : _reloadMethods,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重新加载'),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.primary,
                side: BorderSide(
                  color: scheme.primary.withValues(alpha: 0.40),
                  width: 1.6,
                ),
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
            ? '手续费: ${xbYuan(m.feeFixedYuan!)}'
            : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: _actionsBusy
                ? null
                : () => setState(() => _selectedMethodId = m.id),
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
                        Text(
                          m.name,
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (feeText != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            feeText,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
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
    final pending = _detail?.summary.status == XbOrderStatus.pending;
    return Column(
      children: [
        if (pending) ...[
          FilledButton.icon(
            onPressed: _actionsBusy ? null : _pay,
            icon: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.payment_rounded),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              minimumSize: const Size.fromHeight(XbTokens.hButton),
            ),
            label: const Text('立即支付'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _actionsBusy ? null : _cancel,
            icon: const Icon(Icons.close_rounded, size: 18),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(XbTokens.hButton),
            ),
            label: const Text('取消订单'),
          ),
          const SizedBox(height: 4),
        ],
        TextButton.icon(
          onPressed: _actionsBusy ? null : _checkStatus,
          icon: _checking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded, size: 18),
          label: Text(
            _checking
                ? '正在检测…'
                : _checkFailed
                ? '重新检测'
                : '检测支付状态',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          pending ? '付款后返回此页，可检测订单状态。' : '订单状态将自动更新，无需重复支付。',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<void> _pay() async {
    if (_actionsBusy || _detail?.summary.status != XbOrderStatus.pending) {
      return;
    }
    final owner = _contextVersion;
    final method = _selectedMethodId ?? '';
    await runSubmit(() async {
      final result = await ref
          .read(xboardServiceProvider)
          .checkout(widget.tradeNo, method);
      if (!mounted || owner != _contextVersion) return;
      if (result case XbFailure(:final error)) {
        xbToastSafe('支付失败：${resolveErrorText(error, fallback: '请稍后重试')}');
        return;
      }
      if (!mounted) return;
      await _handleOutcome((result as XbSuccess<CheckoutOutcomeUi>).data);
    });
  }

  Future<void> _handleOutcome(CheckoutOutcomeUi outcome) async {
    final owner = _contextVersion;
    switch (outcome) {
      case CheckoutRedirect(:final url):
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          if (!mounted || owner != _contextVersion) return;
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (mounted && owner == _contextVersion) {
            xbToastSafe('已打开支付页面，完成后返回点「检测支付状态」');
          }
        } else {
          xbToastSafe('无法打开支付页面');
        }
      case CheckoutQrCode(:final qrCodeUrl):
        if (mounted) await _showQrDialog(qrCodeUrl);
      case CheckoutPaid():
        // 由最新详情确认开通结果，T3 仅由 _observeCompletion 触发一次。
        final result = await _refreshAfterMutation();
        if (result != null && owner == _contextVersion) {
          _showCheckFeedback(result);
        }
      case CheckoutCanceled(:final message):
        xbToastSafe(message ?? '已取消');
      case CheckoutFailed(:final message):
        xbToastSafe('支付失败：$message');
    }
  }

  Future<void> _showQrDialog(String qrUrl) async {
    final owner = _contextVersion;
    _qrVisible = true;
    try {
      await xbShowDialog<void>(
        context: context,
        brandColor: xbBrandColor(),
        builder: (ctx) => AlertDialog(
          title: const Text('扫码支付'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 220,
                child: QrImageView(data: qrUrl, size: 220),
              ),
              const SizedBox(height: 12),
              const Text('请用支付宝 / 微信扫描二维码完成支付', textAlign: TextAlign.center),
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
    } finally {
      if (mounted && owner == _contextVersion) _qrVisible = false;
    }
    if (mounted && owner == _contextVersion) {
      final result = await _refreshAfterMutation();
      if (result != null) _showCheckFeedback(result);
    }
  }

  Future<void> _cancel() async {
    if (_actionsBusy || _detail?.summary.status != XbOrderStatus.pending) {
      return;
    }
    final owner = _contextVersion;
    final confirm = await xbConfirm(
      context,
      title: '取消订单',
      message: '确定取消这笔订单吗？',
      confirmLabel: '确定取消',
      cancelLabel: '再想想',
      destructive: true,
    );
    if (!confirm ||
        !mounted ||
        owner != _contextVersion ||
        _actionsBusy ||
        _detail?.summary.status != XbOrderStatus.pending) {
      return;
    }
    await runSubmit(() async {
      final result = await ref
          .read(xboardServiceProvider)
          .cancelOrder(widget.tradeNo);
      if (!mounted || owner != _contextVersion) return;
      switch (result) {
        case XbSuccess(data: true):
          // 成功取消本身已确认终态，不让操作前的详情把页面退回待支付。
          final detail = _detail!;
          setState(
            () => _detail = detail.copyWith(
              summary: detail.summary.copyWith(status: XbOrderStatus.cancelled),
            ),
          );
          _maybeStartPolling();
          _showCheckFeedback(XbResult.success(_detail));
          await _refreshAfterMutation();
        case XbSuccess():
          xbToastSafe('取消失败，请稍后重试');
        case XbFailure(:final error):
          xbToastSafe('取消失败：${resolveErrorText(error, fallback: '请稍后重试')}');
      }
    });
  }

  // ── helpers ──

  Widget _row(String label, String value) =>
      _InfoRow(label: label, value: value);
  Widget _copyableRow(String label, String value) =>
      _CopyableRow(label: label, value: value);
  Widget _totalRow(String label, double yuan) =>
      _TotalRow(label: label, yuan: yuan);

  String _fmtDateTime(DateTime d) => xbDateTime(d);
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
        '开通中',
        '付款已确认，正在开通服务，请勿重复支付。',
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
        '已折抵',
        '订单已折抵到其他订单',
        XbTokens.ok,
      ),
      XbOrderStatus.cancelled => (
        Icons.cancel_rounded,
        '已取消',
        '订单已取消',
        scheme.onSurfaceVariant,
      ),
    };
    final tokens = XbTokens.of(context);
    final foreground = switch (status) {
      XbOrderStatus.pending => tokens.onWarn,
      XbOrderStatus.completed || XbOrderStatus.discounted => tokens.onOk,
      XbOrderStatus.processing =>
        Theme.of(context).brightness == Brightness.dark
            ? Color.lerp(color, tokens.on, .35)!
            : color,
      XbOrderStatus.cancelled => color,
    };
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        children: [
          // 圆形柔色徽标包住状态图标（与订单卡/账号失败卡统一，不裸放大图标）。
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.16),
            ),
            child: _StatusIcon(
              icon: icon,
              color: status == XbOrderStatus.pending ? color : foreground,
              status: status,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态图标：成功态（已完成 / 已抵扣）入场轻微回弹放大（庆祝时刻），其余状态静态。
/// 一次性动画（settle 到 scale 1.0，golden 安全）；尊重「减弱动态效果」。
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
    required this.icon,
    required this.color,
    required this.status,
  });

  final IconData icon;
  final Color color;
  final XbOrderStatus status;

  @override
  Widget build(BuildContext context) {
    final isSuccess = status == XbOrderStatus.completed ||
        status == XbOrderStatus.discounted;
    final iconWidget = Icon(icon, color: color, size: 26);
    if (!isSuccess || XbMotion.reduced(context)) return iconWidget;
    return TweenAnimationBuilder<double>(
      // key 绑定状态：仅在切到成功态时重建并从 0.4 回弹放大到 1.0。
      key: ValueKey(status),
      tween: Tween<double>(begin: 0.4, end: 1.0),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (context, v, child) => Transform.scale(scale: v, child: child),
      child: iconWidget,
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
    final t = XbTokens.of(context);
    final text = Theme.of(context).textTheme;
    // 原型 .secard：白底卡（--card）+ 细描边（--line）+ 轻阴影（sd1）。
    // 不用 scheme.surfaceContainerHigh（M3 灰）——那会让卡片发灰、与原型背景观感不符。
    return Container(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.line),
        boxShadow: t.shadow1,
      ),
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
            child: XbEmojiText(value,
                textAlign: TextAlign.right,
                // 长值（如套餐名）单行省略，防折行 + 右对齐错乱 + 整行变形（与订单号同源修复）。
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
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
                  // 长订单号（可达 28 位）：单行不折行，超长时头部省略保留尾部 + 等宽，
                  // 复制图标固定最右（softWrap 折行会让右对齐错乱、行变形）。
                  Flexible(
                    child: Text(value,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
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
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // 原型 .irow.tot：上方一条细分隔线 + 间距，把「总额」与上面的明细行分隔开。
    return Column(
      children: [
        Container(
            height: 1,
            margin: const EdgeInsets.only(top: 10),
            color: t.line),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              // 标签占剩余宽（超长才省略），把金额顶到右侧。
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              // 金额固定 21px（不用 FittedBox 缩放——它会把总额缩得比明细行金额还小、视觉错位）；
              // 金额很短不会溢出，等宽对齐。
              Text(xbYuan(yuan),
                  style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ),
      ],
    );
  }
}
