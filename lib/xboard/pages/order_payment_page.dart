/// R9 订单/支付页（pending 与终态共用）：订单状态 + 产品信息 + 订单信息 + 支付方式 + 操作。
///
/// **数据源**：反腐层 `getOrder()` / `getPaymentMethods()` / `checkout()` / `cancelOrder()`。
/// pending → 显示支付方式 + 立即支付/取消订单/检查支付状态 + **自动轮询**（pending/processing
/// 每 5s 拉一次 getOrder，终态停）；终态 → 仅显示信息无操作。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/ui/qr_code.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/checkout_outcome_ui.dart';
import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../providers/auth_state_provider.dart';
import '../providers/xboard_providers.dart';
import '../providers/xboard_connectivity_provider.dart';
import '../widgets/xb_network_read_recovery.dart';
import 'commerce_read_recovery.dart';
import '../services/subscription_triggers.dart';
import '../sdk/xboard_service.dart';
import '../shell/widgets/xb_responsive.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_feedback.dart' show xbConfirm, xbBrandColor, XbStateToast;
import '../widgets/xb_center_toast.dart';
import '../widgets/xb_submit_guard.dart';
import '../widgets/xb_theme.dart' show xbShowDialog, XbTokens;
import '../widgets/xb_async_view.dart';
import '../widgets/xb_ui_kit.dart';
import '../widgets/xb_emoji_text.dart';
import '../widgets/xb_payment_channel_icon.dart';

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
  final _methodsFocus = FocusNode(skipTraversal: true);
  final _retryLabel = GlobalKey();
  bool _methodsReloading = false;
  Future<void>? _channelRead;
  Future<void>? _initialRead;
  Object? _methodsFailure;
  Object? _statusFailure;
  bool _paying = false;
  bool _cancelling = false;
  final _firstMethodFocus = FocusNode();
  Object? _loadError;
  bool _loading = true;
  bool _retrying = false; // 重试中 → 顶部「正在刷新服务」黄条
  Timer? _pollTimer;
  bool _paymentAttempted = false;
  bool _autoChecking = false;
  Future<_OrderRead>? _orderRead;
  int _contextVersion = 0;
  int _readVersion = 0;
  int _loadAttempt = 0;
  bool _checking = false;
  bool _checkFailed = false;
  bool _requiresNetworkCheck = false;
  bool _completionTriggered = false;
  bool _qrVisible = false;
  bool _launchingPayment = false;
  bool _returnedDuringLaunch = false;
  bool _redirectNeedsCheck = false;
  bool _checkingReturn = false;
  bool _foreground = true;
  ProviderSubscription<AuthState>? _authSubscription;
  ProviderSubscription<XboardService>? _serviceSubscription;
  VoidCallback? _dismissFeedback;

  bool get _actionsBusy => submitting || _loading ||
      _methodsReloading || ref.read(isOfflineProvider);
  bool get _canMutate =>
      !_actionsBusy && !_requiresNetworkCheck && !_redirectNeedsCheck && !_checkFailed &&
      _detail?.summary.status == XbOrderStatus.pending;
  bool get _canPay =>
      _canMutate &&
      !_methodsError &&
      _methods.any((m) => m.id.trim().isNotEmpty && m.id == _selectedMethodId);

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
  void dispose() {
    ++_contextVersion;
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.close();
    _serviceSubscription?.close();
    _pollTimer?.cancel();
    _firstMethodFocus.dispose();
    _methodsFocus.dispose();
    _dismissFeedback?.call();
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
    if (ref.read(isOfflineProvider)) return;
    if (ModalRoute.of(context)?.isCurrent == false && !_qrVisible) return;
    if (_detail != null && !_isTerminal(_detail!.summary.status)) {
      if (_launchingPayment) {
        _returnedDuringLaunch = true;
      } else if (!submitting && !_checking) {
        unawaited(_checkOnReturn());
      } else if (_qrVisible) {
        unawaited(_refreshStatus());
      }
      _maybeStartPolling();
    }
  }

  void _resetContext({Object? error}) {
    _channelRead = null;
    _initialRead = null;
    ++_contextVersion;
    ++_readVersion;
    ++_loadAttempt;
    _orderRead = null;
    _pollTimer?.cancel();
    _dismissFeedback?.call();
    setState(() {
      _paymentAttempted = false;
      _autoChecking = false;
      _detail = null;
      _methods = const [];
      _methodsError = false;
      _methodsReloading = false;
      _methodsFailure = null;
      _statusFailure = null;
      _paying = false;
      _cancelling = false;
      _selectedMethodId = null;
      _loadError = error;
      _loading = false;
      _retrying = false;
      _checking = false;
      _checkFailed = false;
      _requiresNetworkCheck = false;
      _completionTriggered = false;
      _qrVisible = false;
      _launchingPayment = false;
      _returnedDuringLaunch = false;
      _redirectNeedsCheck = false;
      _checkingReturn = false;
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
    request =
        (() async {
          XbResult<OrderDetail?> result;
          try {
            result = ref.read(isOfflineProvider)
                ? const XbFailure(XbNetwork(XbNetworkKind.connectionFailed, '当前离线'))
                : await service.getOrder(tradeNo);
            if (result case XbSuccess(
              :final data,
            ) when data != null && (data.summary.tradeNo != tradeNo || data.summary.needsVerification)) {
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

  Future<void> _initialLoad({bool retry = false}) {
    final existing = _initialRead;
    if (existing != null) return existing;
    final request = _loadInitialDetail(retry: retry);
    _initialRead = request;
    return request.whenComplete(() {
      if (identical(_initialRead, request)) _initialRead = null;
    });
  }

  Future<void> _loadInitialDetail({required bool retry}) async {
    final attempt = ++_loadAttempt;
    setState(() {
      _loading = true;
      _retrying = retry;
      _loadError = null;
    });
    try {
      final read = await _readOrder();
      if (!_isCurrentRead(read) || attempt != _loadAttempt) return;
      final detail = switch (read.result) {
        XbSuccess(:final data) => data,
        XbFailure(:final error) => throw error, // 抛领域错误，_errorRetry 还原文案
      };
      setState(() {
        _detail = detail == null ? null : _acceptedDetail(detail);
        _loading = false;
        _retrying = false;
        _loadError = null;
        _checkFailed = false;
      });
      _observeCompletion();
      _maybeStartPolling();
      if (_detail?.summary.status == XbOrderStatus.pending) unawaited(_reloadMethods());
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
  Future<void> _reloadMethods() {
    final existing = _channelRead;
    if (existing != null) return existing;
    final request = _readMethods();
    _channelRead = request;
    return request.whenComplete(() {
      if (identical(_channelRead, request)) _channelRead = null;
    });
  }

  Future<void> _readMethods() async {
    if (ref.read(isOfflineProvider)) {
      setState(() {
        _methodsError = true;
        _methodsFailure = const XbNetwork(XbNetworkKind.connectionFailed, '当前离线');
      });
      return;
    }
    if (_actionsBusy || _detail?.summary.status != XbOrderStatus.pending) return;
    final owner = _contextVersion;
    final label = _retryLabel.currentContext;
    final restoreFocus = label != null && Focus.of(label).hasPrimaryFocus;
    if (restoreFocus) _methodsFocus.requestFocus();
    setState(() => _methodsReloading = true);
    try {
      final mRes = await ref.read(xboardServiceProvider).getPaymentMethods();
      if (!mounted || owner != _contextVersion) return;
      setState(() {
        switch (mRes) {
          case XbSuccess(:final data):
            _methods = data;
            _methodsError = false;
            _methodsFailure = null;
            _selectedMethodId = data.isNotEmpty ? data.first.id : null;
          case XbFailure(:final error):
            _methodsError = true;
            _methodsFailure = error;
        }
      });
    } catch (e) {
      if (mounted && owner == _contextVersion) {
        setState(() {
          _methodsError = true;
          _methodsFailure = e;
        });
      }
    } finally {
      if (mounted && owner == _contextVersion) setState(() => _methodsReloading = false);
    }
    if (restoreFocus && mounted && owner == _contextVersion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || owner != _contextVersion || !_methodsFocus.hasPrimaryFocus) return;
        final label = _retryLabel.currentContext;
        final target = _methodsError ? (label == null ? null : Focus.of(label)) : _firstMethodFocus;
        if (target != null && target.context != null && target.canRequestFocus) target.requestFocus();
      });
    }
  }

  /// 静默刷新（轮询 / 检查支付状态用，不显示全屏 loading）。
  Future<XbResult<OrderDetail?>?> _refreshStatus() async {
    final owner = _contextVersion;
    try {
      final read = await _readOrder();
      if (!_isCurrentRead(read)) return null;
      if (read.result case XbSuccess(:final data) when data != null) {
        setState(() {
          _detail = _acceptedDetail(data);
          _checkFailed = false;
          _requiresNetworkCheck = ref.read(isOfflineProvider);
          _statusFailure = _requiresNetworkCheck
              ? const XbNetwork(XbNetworkKind.connectionFailed, '当前离线') : null;
          _redirectNeedsCheck = false;
        });
        _observeCompletion();
        _maybeStartPolling();
        return XbResult.success(_detail);
      }
      setState(() {
        _checkFailed = true;
        _statusFailure = read.result.errorOrNull;
      });
      _maybeStartPolling();
      if (read.result case XbFailure()) return read.result;
      return XbResult<OrderDetail?>.failure(
        const XbUnexpected('getOrder', '暂未获取到最新订单状态。'),
      );
    } catch (error) {
      if (!mounted || owner != _contextVersion) return null;
      setState(() { _checkFailed = true; _statusFailure = error; });
      _maybeStartPolling();
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

  Future<void> _checkOnReturn() async {
    if (_checkingReturn) return;
    final owner = _contextVersion;
    setState(() => _checkingReturn = true);
    try {
      if (_redirectNeedsCheck || submitting) {
        await _refreshAfterMutation();
      } else {
        await _refreshStatus();
      }
    } finally {
      if (mounted && owner == _contextVersion) {
        setState(() => _checkingReturn = false);
      }
    }
    if (mounted && owner == _contextVersion && _foreground &&
        ModalRoute.of(context)?.isCurrent != false &&
        _detail?.summary.status == XbOrderStatus.pending &&
        xbIsRecoverableReadError(_methodsFailure)) {
      await _reloadMethods();
    }
  }

  Future<void> _checkStatus() async {
    if (_actionsBusy || _autoChecking || _checking || _checkingReturn) return;
    final owner = _contextVersion;
    _dismissFeedback?.call();
    setState(() {
      _checking = true;
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
      XbSuccess(:final data) => switch (data!.summary.status!) {
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
        !ref.read(isOfflineProvider) && (_statusFailure == null || xbIsRecoverableReadError(_statusFailure)) &&
        (status == XbOrderStatus.pending && _paymentAttempted || status == XbOrderStatus.processing);
    if (shouldPoll && (_pollTimer == null || !_pollTimer!.isActive)) {
      _pollTimer = Timer.periodic(_kPollInterval, (_) {
        if (!_loading && !_autoChecking && (ModalRoute.of(context)?.isCurrent != false || _qrVisible) &&
            (!submitting || _paying || _qrVisible) && !_methodsReloading &&
            !_checking && !_checkingReturn &&
            !ref.read(isOfflineProvider) && _orderRead == null) {
          unawaited(_pollOnce());
        }
      });
    } else if (!shouldPoll) {
      _pollTimer?.cancel();
    }
  }

  Future<void> _pollOnce() async {
    final owner = _contextVersion;
    setState(() => _autoChecking = true);
    try {
      final previous = _detail?.summary.status;
      final result = await _refreshStatus();
      if (mounted && owner == _contextVersion && result is XbSuccess<OrderDetail?> &&
          _isTerminal(_detail?.summary.status) && previous != _detail?.summary.status &&
          ModalRoute.of(context)?.isCurrent == true) {
        _showCheckFeedback(result);
      }
    } finally {
      if (mounted && owner == _contextVersion) setState(() => _autoChecking = false);
    }
  }

  bool _isTerminal(XbOrderStatus? s) =>
      s == XbOrderStatus.cancelled ||
      s == XbOrderStatus.completed ||
      s == XbOrderStatus.discounted;

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(isOfflineProvider);
    ref.listen(isOfflineProvider, (_, next) {
      if (next) {
        _pollTimer?.cancel();
        if (_detail != null && !_isTerminal(_detail!.summary.status) &&
            (_statusFailure == null || xbIsRecoverableReadError(_statusFailure))) {
          setState(() {
            _checkFailed = true;
            _requiresNetworkCheck = true;
            _statusFailure = const XbNetwork(XbNetworkKind.connectionFailed, '当前离线');
          });
        }
      }
    });
    xbListenForReadRecovery(context, ref, () async {
      final owner = _contextVersion;
      bool current() => mounted && owner == _contextVersion && _foreground &&
          ref.read(authStateProvider) == AuthState.authenticated && !ref.read(isOfflineProvider);
      if (!current() || submitting) return;
      final initial = _initialRead;
      final channel = _channelRead;
      final detail = _orderRead;
      await recoverCommerceRead(context: context, current: current,
        pending: Future.wait<void>([
          ?initial,
          ?channel,
          if (detail != null) detail.then<void>((_) {}),
        ]),
        retryIfFailed: () async {
          if (_actionsBusy) return;
          if (xbIsRecoverableReadError(_loadError)) {
            await _initialLoad(retry: true);
            return;
          }
          final retryChannels = xbIsRecoverableReadError(_methodsFailure);
          if (_statusFailure != null && !xbIsRecoverableReadError(_statusFailure)) return;
          if (_requiresNetworkCheck || xbIsRecoverableReadError(_statusFailure) ||
              retryChannels && _detail?.summary.status == XbOrderStatus.pending) {
            // A missing channel list is meaningful only if this very order
            // still needs payment. Don't fetch channels for a newly closed order.
            final latest = await _refreshStatus();
            if (latest is! XbSuccess<OrderDetail?>) return;
          }
          if (!context.mounted || !current() || ModalRoute.of(context)?.isCurrent == false) return;
          if (_detail?.summary.status == XbOrderStatus.pending &&
              xbIsRecoverableReadError(_methodsFailure)) {
            await _reloadMethods();
          }
          if (current()) _maybeStartPolling();
        });
    });
    // 按页面实际可用宽度排布，桌面侧栏与嵌套 Navigator 已占用的空间不参与双栏判断。
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = xbIsDesktopWidth(constraints.maxWidth);
        return XbBrandScaffold(
          title: '订单详情',
          actions: [
            if (_detail?.summary.status case final XbOrderStatus status when _loadError == null)
              Padding(padding: const EdgeInsetsDirectional.only(end: 16),
                  child: Center(child: _OrderStatusBadge(status: status))),
          ],
          maxContentWidth: wide ? 1000 : null,
          body: XbAsyncView(
            loading: _loading && !_retrying,
            retrying: _retrying,
            error: _loadError,
            errorFallback: '加载订单失败',
            onRetry: () => _initialLoad(retry: true),
            builder: (context) => _detail == null
                ? const Center(child: Text('订单不存在'))
                : offline ? Column(children: [
                  const Text('当前离线，显示上次读取的订单'),
                  Expanded(child: _content(context, _detail!, wide)),
                ]) : _content(context, _detail!, wide),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context, OrderDetail detail, bool wide) {
    final s = detail.summary;
    final isPending = s.status == XbOrderStatus.pending;
    final canCheck = !_isTerminal(s.status);
    final netCents = (s.totalAmountYuan! * 100).round();
    final productCard = _SectionCard(
      compact: !wide,
      children: [
        _InfoRow(label: '套餐内容', value: "${s.planName ?? '套餐订单'} · ${planPeriodLabel(s.period)}", compact: !wide),
      ],
    );
    final orderCard = _SectionCard(
      compact: !wide,
      title: '订单信息',
      children: [
        _CopyableRow(label: '订单号', value: s.tradeNo, compact: !wide),
        _InfoRow(label: '创建时间', value: _fmtDateTime(s.createdAt), compact: !wide),
        ..._amountRows(detail, netCents, compact: !wide),
      ],
    );

    if (wide) {
      final information = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [productCard, const SizedBox(height: 16), orderCard],
      );
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
        child: !canCheck
            ? Center(child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: information,
              ))
            : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 21,
              child: information,
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
                      children: [_paymentMethods(context, netCents: netCents)],
                    ),
                    const SizedBox(height: 20),
                  ],
                  _actions(context),
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
        productCard,
        const SizedBox(height: 9),
        orderCard,
        if (isPending) ...[
          const SizedBox(height: 9),
          _SectionCard(
            compact: true,
            title: '支付方式',
            children: [_paymentMethods(context, netCents: netCents, compact: true)],
          ),
        ],
        if (canCheck) ...[const SizedBox(height: 9), _actions(context, compact: true)],
      ],
    );
  }

  List<Widget> _amountRows(OrderDetail detail, int netCents, {required bool compact}) {
    final discount = ((detail.discountAmountYuan ?? 0) * 100).round();
    final balanceCents = ((detail.balanceAmountYuan ?? 0) * 100).round();
    final balance = balanceCents > 0 ? balanceCents : 0;
    final surplus = ((detail.surplusAmountYuan ?? 0) * 100).round();
    final creditYuan = detail.surplusCreditYuan;
    final credit = creditYuan == null ? null : (creditYuan * 100).round();
    final applied = appliedOrderSurplusCents(net: netCents, balance: balance, surplus: surplus, credit: credit);
    final selected = _methods.where((m) => m.id == _selectedMethodId).firstOrNull;
    // 待付订单以当前渠道配置为准，不复用此前支付尝试留下的手续费。
    final feeCents = detail.summary.status == XbOrderStatus.pending
        ? _channelFeeCents(netCents, selected)
        : ((detail.handlingAmountYuan ?? 0) * 100).round();
    final fee = feeCents;
    Widget row(String label, String value) => _InfoRow(label: label, value: value, compact: compact);
    return [
      if (applied != null)
        row(discount > 0 || surplus > 0 ? '抵扣前订单金额' : '订单金额',
            xbYuan((netCents + balance + discount + applied) / 100)),
      if (discount > 0) row('订单优惠（已抵扣）', xbYuanMinus(discount / 100)),
      if (applied != null && applied > 0) row('旧套餐结余抵扣', xbYuanMinus(applied / 100)),
      if (applied == null && surplus > 0) row('旧套餐结余（抵扣额待核实）', xbYuan(surplus / 100)),
      if (balance > 0) row('余额抵扣', xbYuanMinus(balance / 100)),
      if (fee != 0) row('支付手续费', fee < 0 ? xbYuanMinus(fee / 100) : xbYuan(fee / 100)),
      _TotalRow(label: '应付金额', yuan: (netCents + fee) / 100, compact: compact),
      // A separate credit recorded for this order, not a second deduction or
      // evidence that a pending/cancelled order already credited the account.
      if (credit != null && credit > 0) row('结余返还金额', xbYuan(credit / 100)),
    ];
  }

  int _channelFeeCents(int netCents, PaymentMethodItem? method) {
    // Xboard checkout 对零元订单不计费，否则比例费与固定费合计后舍入到分。
    if (netCents <= 0 || method == null) return 0;
    final fixedYuan = method.feeFixedYuan ?? 0;
    final percent = method.feePercent ?? 0;
    if (!fixedYuan.isFinite || !percent.isFinite) return 0;
    final fixedCents = (fixedYuan * 100).round();
    return (netCents * (percent / 100) + fixedCents).round();
  }

  String _channelFeeText(int netCents, PaymentMethodItem method) {
    if (netCents <= 0 || ((method.feePercent ?? 0) == 0 && (method.feeFixedYuan ?? 0) == 0)) return '免手续费';

    final percent = method.feePercent ?? 0;
    final fixedYuan = method.feeFixedYuan ?? 0;
    final rate = percent.toString().replaceFirst(RegExp(r'\.0$'), '');
    final configuration = [
      if (percent != 0) '$rate%',
      if (fixedYuan > 0) xbYuan(fixedYuan),
    ].join(' + ');
    final fixedDiscount = fixedYuan < 0 ? '${configuration.isEmpty ? '-' : ' - '}${xbYuan(-fixedYuan)}' : '';
    return '手续费 $configuration$fixedDiscount';
  }

  Widget _paymentMethods(BuildContext context, {required int netCents, bool compact = false}) {
    return Focus(
      focusNode: _methodsFocus,
      child: _methodChoices(context, netCents: netCents, compact: compact),
    );
  }

  Widget _methodChoices(BuildContext context, {required int netCents, required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    // 加载失败 → 小重试块（替代「暂无支付方式」死胡同，原型 17b）。仅重拉支付方式，不动订单。
    if (_methodsError || _methodsReloading) {
      return SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(
                _methodsReloading ? '正在加载支付方式…' : '支付方式加载失败',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              XbGradientAction(
                height: 48,
                onPressed: _actionsBusy ? null : _reloadMethods,
                busyLabel: _methodsReloading ? '正在加载…' : null,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.refresh_rounded, size: 18),
                  const SizedBox(width: 7),
                  Text('重新加载', key: _retryLabel),
                ]),
              ),
            ],
          ),
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
        final feeText = _channelFeeText(netCents, m);
        return Padding(
          padding: EdgeInsets.only(bottom: compact ? 0 : 8),
          child: Semantics(selected: selected, child: InkWell(
            focusNode: identical(m, _methods.first) ? _firstMethodFocus : null,
            onTap: _actionsBusy
                ? null
                : () => setState(() => _selectedMethodId = m.id),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              constraints: compact ? const BoxConstraints(minHeight: 44) : null,
              padding: compact
                  ? const EdgeInsets.symmetric(vertical: 6)
                  : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: compact ? null : BoxDecoration(
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
                  XbPaymentChannelIcon(url: m.icon),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.name,
                          style: text.titleSmall?.copyWith(
                            fontSize: compact ? 16 : null,
                            height: compact ? 1.5 : null,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        ...[
                          const SizedBox(height: 2),
                          Text(
                            feeText,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: compact ? 10.5 : null,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_outline
                        : Icons.radio_button_unchecked,
                    size: compact ? 20 : null,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          )),
        );
      }).toList(),
    );
  }

  Widget _actions(BuildContext context, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final t = XbTokens.of(context);
    final pending = _detail?.summary.status == XbOrderStatus.pending;
    final checking = _autoChecking || _checking || _checkingReturn;
    return Column(
      children: [
        if (pending) ...[
          SizedBox(width: double.infinity, child: XbGradientAction(
            height: 48,
            tintWhenDisabled: true,
            onPressed: _canPay ? _pay : null,
            busyLabel: _paying && !_checkingReturn ? '正在支付…' : null,
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.payment_rounded, size: 19),
              SizedBox(width: 8),
              Flexible(child: Text('立即支付')),
            ]),
          )),
          SizedBox(height: compact ? 6 : 10),
        ],
        OutlinedButton(
          onPressed: checking || _actionsBusy ? null : _checkStatus,
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            minimumSize: Size.fromHeight(compact ? 44 : XbTokens.hButton),
            side: BorderSide(color: checking || _actionsBusy ? t.line : Color.lerp(t.line, scheme.primary, .4)!, width: 1.5),
            disabledForegroundColor: t.onv,
            disabledIconColor: t.onv,
            disabledBackgroundColor: checking ? Colors.transparent : t.sfc,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(checking ? Icons.hourglass_empty_rounded : Icons.refresh_rounded, size: 18),
            const SizedBox(width: 7),
            Flexible(child: Text(checking ? '支付状态检查中' : '检查支付状态')),
          ]),
        ),
        if (pending) ...[
          SizedBox(height: compact ? 6 : 10),
          OutlinedButton(
            onPressed: _canMutate ? _cancel : null,
            style: OutlinedButton.styleFrom(
              minimumSize: Size.fromHeight(compact ? 40 : XbTokens.hButton),
              disabledForegroundColor: t.onv,
              disabledIconColor: t.onv,
              disabledBackgroundColor: t.sfc,
              side: BorderSide(color: _canMutate ? Color.lerp(t.line, scheme.primary, .40)! : t.line, width: 1.5),
            ),
            child: _cancelling ? Text('正在取消…', textAlign: TextAlign.center, style: TextStyle(color: t.onv))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.close_rounded, size: 18, color: _canMutate ? null : t.onv),
                    const SizedBox(width: 8),
                    Flexible(child: Text('取消订单', style: TextStyle(color: _canMutate ? null : t.onv))),
                  ]),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          ref.read(isOfflineProvider) ? '网络已断开，恢复后再核对订单。'
              : _checkFailed && (_paymentAttempted || !pending) && xbIsRecoverableReadError(_statusFailure)
                  ? '暂未确认，将在 5 秒后再检测。'
              : _checkFailed ? '订单状态尚未确认，请重新检测。'
              : _paymentAttempted || !pending ? '每 5 秒自动检测，也可手动检测。' : '付款后返回此页，可检测订单状态。',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<void> _pay() async {
    if (!_canPay) {
      return;
    }
    final owner = _contextVersion;
    final method = _selectedMethodId!;
    await runSubmit(() async {
      setState(() { _paying = true; _paymentAttempted = true; });
      _maybeStartPolling();
      try {
        final result = await ref
            .read(xboardServiceProvider)
            .checkout(widget.tradeNo, method);
        if (!mounted || owner != _contextVersion) return;
        if (result case XbFailure(:final error)) {
          xbToastSafe(
            error is XbUnconfirmed
                ? resolveErrorText(error)
                : '支付失败：${resolveErrorText(error, fallback: '请稍后重试')}',
          );
          if (error is XbUnconfirmed) await _refreshAfterMutation();
          return;
        }
        if (_isTerminal(_detail?.summary.status)) return;
        await _handleOutcome((result as XbSuccess<CheckoutOutcomeUi>).data);
      } finally {
        if (mounted && owner == _contextVersion) setState(() => _paying = false);
      }
    });
  }

  Future<void> _openExternalPayment(String url) async {
    final owner = _contextVersion;
    bool current() => mounted && owner == _contextVersion;
    _launchingPayment = true;
    _returnedDuringLaunch = false;
    var opened = false;
    try {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.hasScheme && await canLaunchUrl(uri) && current()) {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } on Exception {
      // Being able to resolve a URL does not guarantee the OS will open it.
    } finally {
      if (current()) _launchingPayment = false;
    }
    if (!current()) return;
    final returned = _returnedDuringLaunch;
    _returnedDuringLaunch = false;
    if (opened) {
      ++_readVersion; // A status read from before handoff cannot unlock payment.
      setState(() => _redirectNeedsCheck = true);
      if (!returned) xbToastSafe('已打开支付页面，完成后返回点「检查支付状态」');
    } else {
      xbToastSafe('无法打开支付页面');
    }
    if (returned && _foreground) await _checkOnReturn();
  }

  Future<void> _handleOutcome(CheckoutOutcomeUi outcome) async {
    final owner = _contextVersion;
    switch (outcome) {
      case CheckoutRedirect(:final url):
        await _openExternalPayment(url);
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
                child: QrCodeView(data: qrUrl, size: 220),
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
    if (!_canMutate) {
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
        !_canMutate) {
      return;
    }
    await runSubmit(() async {
      setState(() => _cancelling = true);
      try {
        final result = await ref.read(xboardServiceProvider).cancelOrder(widget.tradeNo);
        if (!mounted || owner != _contextVersion) return;
        switch (result) {
          case XbSuccess(data: true):
            final detail = _detail!;
            setState(() => _detail = detail.copyWith(
              summary: detail.summary.copyWith(status: XbOrderStatus.cancelled),
            ));
            _maybeStartPolling();
            _showCheckFeedback(XbResult.success(_detail));
            await _refreshAfterMutation();
          case XbSuccess():
            xbToastSafe('取消失败，请稍后重试');
          case XbFailure(:final error):
            xbToastSafe(error is XbUnconfirmed
                ? resolveErrorText(error)
                : '取消失败：${resolveErrorText(error, fallback: '请稍后重试')}');
            if (error is XbUnconfirmed) await _refreshAfterMutation();
        }
      } finally {
        if (mounted && owner == _contextVersion) setState(() => _cancelling = false);
      }
    });
  }

  // ── helpers ──

  String _fmtDateTime(DateTime d) => xbDateTime(d);
}

class _OrderStatusBadge extends StatelessWidget {
  const _OrderStatusBadge({required this.status});
  final XbOrderStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, title, color) = switch (status) {
      XbOrderStatus.pending => (Icons.schedule_rounded, '待支付', XbTokens.warn),
      XbOrderStatus.processing => (Icons.hourglass_top_rounded, '开通中', XbTokens.info),
      XbOrderStatus.completed => (Icons.check_circle_outline, '已完成', XbTokens.ok),
      XbOrderStatus.discounted => (Icons.swap_horiz_rounded, '已折抵', XbTokens.ok),
      XbOrderStatus.cancelled => (Icons.cancel_outlined, '已取消', Theme.of(context).colorScheme.onSurfaceVariant),
    };
    final tokens = XbTokens.of(context);
    final foreground = switch (status) {
      XbOrderStatus.pending => tokens.onWarn,
      XbOrderStatus.completed || XbOrderStatus.discounted => Theme.of(context).brightness == Brightness.light
          ? Color.lerp(tokens.onOk, Colors.black, .20)! : tokens.onOk,
      XbOrderStatus.processing =>
        Theme.of(context).brightness == Brightness.dark
            ? Color.lerp(color, tokens.on, .35)!
            : color,
      XbOrderStatus.cancelled => color,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: ShapeDecoration(color: color.withValues(alpha: .12), shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: foreground),
        const SizedBox(width: 5),
        Text(title, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: foreground, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// 信息分区卡（标题 + 子行）。
class _SectionCard extends StatelessWidget {
  const _SectionCard({this.title, required this.children, this.compact = false});
  final String? title;
  final List<Widget> children;
  final bool compact;

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
        padding: compact ? const EdgeInsets.symmetric(horizontal: 13, vertical: 11) : const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title case final String heading) ...[
            Text(
              heading,
              style: text.titleMedium?.copyWith(fontSize: compact ? 13 : null, color: compact ? t.onv : null, fontWeight: compact ? FontWeight.w600 : FontWeight.w700),
            ),
            SizedBox(height: compact ? 6 : 12),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.compact = false});
  final bool compact;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: XbEmojiText(
              value,
              textAlign: TextAlign.right,
              // 长值（如套餐名）单行省略，防折行 + 右对齐错乱 + 整行变形（与订单号同源修复）。
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableRow extends StatelessWidget {
  const _CopyableRow({required this.label, required this.value, required this.compact});
  final bool compact;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('订单号已复制')));
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // 长订单号（可达 28 位）：单行不折行，超长时头部省略保留尾部 + 等宽，
                  // 复制图标固定最右（softWrap 折行会让右对齐错乱、行变形）。
                  Flexible(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.copy_rounded,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
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
  const _TotalRow({required this.label, required this.yuan, required this.compact});
  final bool compact;
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
          margin: EdgeInsets.only(top: compact ? 5 : 10),
          color: t.line,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              // 标签占剩余宽（超长才省略），把金额顶到右侧。
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              // 金额固定 21px（不用 FittedBox 缩放——它会把总额缩得比明细行金额还小、视觉错位）；
              // 金额很短不会溢出，等宽对齐。
              Text(
                xbYuan(yuan),
                style: TextStyle(
                  fontSize: compact ? 19 : 21,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
