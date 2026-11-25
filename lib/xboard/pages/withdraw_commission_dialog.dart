import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../providers/auth_state_provider.dart';
import '../providers/invite_provider.dart';
import '../providers/xboard_providers.dart';
import '../sdk/xboard_service.dart';
import '../services/withdraw_eligibility.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../widgets/xb_feedback.dart' show XbStateToast;
import '../widgets/xb_purchase_confirmation.dart' show XbPurchaseActions;
import '../widgets/xb_theme.dart' show XbTokens;
import '../widgets/xb_network_read_recovery.dart';
import 'commission_pending_review.dart';

/// Preflight and application are separate steps. Neither a passing preflight
/// nor a successful application indicates that commission has been paid out.
class WithdrawCommissionDialog extends ConsumerStatefulWidget {
  const WithdrawCommissionDialog({
    super.key,
    required this.owner,
    required this.revision,
  });

  final XboardService owner;
  final int revision;

  @override
  ConsumerState<WithdrawCommissionDialog> createState() =>
      _WithdrawCommissionDialogState();
}

class _WithdrawCommissionDialogState
    extends ConsumerState<WithdrawCommissionDialog> {
  final _account = TextEditingController();
  ModalRoute<dynamic>? _route;
  int _generation = 0;
  bool _closed = false;
  bool _balanceChecking = false;
  bool _recordsChecking = false;
  Object? _balanceError, _recordsError, _methodsError;
  bool _recoveryPending = false;
  int? _balanceCents;
  int? _paidRecords;
  bool _form = false;
  bool _methodsChecking = false;
  List<String> _methods = const [];
  String? _method;
  bool _confirmed = false;
  bool _submitting = false;
  bool _unconfirmed = false;

  bool get _current =>
      mounted &&
      !_closed &&
      (_route?.isActive ?? true) &&
      _route?.animation?.status != AnimationStatus.reverse &&
      ref.read(authStateProvider) == AuthState.authenticated &&
      ref.read(authStateProvider.notifier).sessionRevision == widget.revision &&
      identical(ref.read(xboardServiceProvider), widget.owner);

  bool get _checking => _balanceChecking || _recordsChecking;
  bool get _eligible =>
      !_checking &&
      (_balanceCents ?? -1) >= withdrawMinimumCents &&
      (_paidRecords ?? -1) >= withdrawMinimumPaidRecords;
  bool get _hasDetails =>
      _methods.contains(_method) && _account.text.trim().isNotEmpty;
  bool get _canSubmit =>
      _form &&
      _eligible &&
      !_methodsChecking &&
      _hasDetails &&
      _confirmed &&
      !_submitting &&
      !_unconfirmed;

  @override
  void initState() {
    super.initState();
    _checkEligibility();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _closed = true;
    _account.dispose();
    super.dispose();
  }

  Future<T> _withValidity<T>(
    bool Function() isActive,
    Future<T> Function() request,
  ) {
    final service = widget.owner;
    return service is XboardInviteRequestControl
        ? (service as XboardInviteRequestControl).withInviteRequestValidity(
            isActive,
            request,
          )
        : request();
  }

  void _checkEligibility({bool failedOnly = false}) {
    if (!_current || _form || _checking || _submitting) return;
    final balance = !failedOnly || xbIsRecoverableReadError(_balanceError);
    final records = !failedOnly || xbIsRecoverableReadError(_recordsError);
    final session = ref.read(commissionSessionProvider);
    if ((!balance && !records) || !session.acquire()) return;
    final generation = ++_generation;
    setState(() {
      if (balance) { _balanceChecking = true; _balanceCents = null; _balanceError = null; }
      if (records) { _recordsChecking = true; _paidRecords = null; _recordsError = null; }
    });
    bool active() => _current && generation == _generation && !_form;
    unawaited(Future.wait([
      if (balance) session.readersDone.then((_) async { if (active()) await _checkBalance(active); }),
      if (records) session.readersDone.then((_) async { if (active()) await _checkRecords(active); }),
    ]).then<void>((_) {}).whenComplete(() {
      session.release();
      _drainRecovery();
    }));
  }

  Future<void> _checkBalance(bool Function() active) async {
    int? cents;
    Object? failure;
    try {
      // Read directly from the service, not the painted card or inviteInfoProvider
      // (the provider may generate an invitation code as a side effect).
      final result = await _withValidity(active, widget.owner.getInviteInfo);
      failure = result.errorOrNull;
      if (result case XbSuccess(:final data)) {
        cents = withdrawBalanceCents(data.commissionBalanceYuan);
      }
    } catch (error) {
      failure = error;
    }
    if (!active()) return;
    setState(() {
      _balanceChecking = false;
      _balanceCents = cents;
      _balanceError = failure;
    });
  }

  Future<void> _checkRecords(bool Function() active) async {
    int? count;
    Object? failure;
    try {
      final result = await _withValidity(
        active,
        widget.owner.getWithdrawalRecordCount,
      );
      failure = result.errorOrNull;
      if (result case XbSuccess(:final data)) {
        count = data;
      }
    } catch (error) {
      failure = error;
    }
    if (!active()) return;
    setState(() {
      _recordsChecking = false;
      _paidRecords = count;
      _recordsError = failure;
    });
  }

  void _continue() {
    if (!_current || !_eligible || _form) return;
    setState(() => _form = true);
    unawaited(_loadMethods());
  }

  Future<void> _loadMethods() async {
    if (!_current || !_form || _methodsChecking || _submitting) return;
    final session = ref.read(commissionSessionProvider);
    if (!session.acquire()) return;
    final generation = ++_generation;
    setState(() {
      _methodsChecking = true;
      _methodsError = null;
      _methods = const [];
      _method = null;
      _confirmed = false;
    });
    bool active() => _current && _form && generation == _generation;
    List<String> methods = const [];
    Object? failure;
    try {
      await session.readersDone;
      if (!active()) return;
      final result = await _withValidity(active, widget.owner.getWithdrawMethods);
      failure = result.errorOrNull;
      if (result case XbSuccess(:final data)) {
        methods = data
            .where((method) => method.trim().isNotEmpty)
            .toSet()
            .toList();
      }
    } catch (error) {
      failure = error;
    } finally {
      session.release();
    }
    if (!active()) return;
    setState(() {
      _methods = methods;
      _methodsChecking = false;
      _methodsError = failure;
    });
    _drainRecovery();
  }

  void _drainRecovery() {
    if (!_recoveryPending || _checking || _methodsChecking) return;
    _recoveryPending = false;
    if (!_current || _route?.isCurrent != true || _submitting || _unconfirmed ||
        (WidgetsBinding.instance.lifecycleState != null &&
         WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    if (!_form) {
      _checkEligibility(failedOnly: true);
    } else if (_methods.isEmpty && xbIsRecoverableReadError(_methodsError)) {
      unawaited(_loadMethods());
    }
  }

  Future<void> _submit() async {
    if (!_current || !_canSubmit) return;
    final session = ref.read(commissionSessionProvider);
    if (!session.acquire()) return;
    final cents = _balanceCents!;
    final method = _method!;
    final account = _account.text.trim();
    setState(() => _submitting = true);
    try {
      await session.readersDone;
      if (!_current) return;
      final result = await _withValidity(
        () => _current && _submitting,
        () => widget.owner.withdrawCommission(method: method, account: account),
      );
      if (commissionWriteNeedsReview(result)) {
        session.markUnknown('提现申请', cents);
      }
      if (!_current) return;
      switch (result) {
        case XbSuccess(data: true):
          session.allowCodeGeneration = false;
          ref.invalidate(inviteInfoProvider);
          ref.invalidate(commissionRecordsProvider);
          xbToastSafe('提现申请已提交，请等待人工审核。');
          _close();
        case XbSuccess():
        case XbFailure(error: XbUnconfirmed()):
          _showUnconfirmed();
        case XbFailure(:final error):
          xbToastSafe(resolveErrorText(error, fallback: '提现失败，请重试'));
      }
    } catch (_) {
      session.markUnknown('提现申请', cents);
      if (_current) _showUnconfirmed();
    } finally {
      session.release();
      if (_current) setState(() => _submitting = false);
    }
  }

  void _showUnconfirmed() {
    setState(() => _unconfirmed = true);
  }

  void _close() {
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) return;
    _closed = true;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(authStateProvider);
    ref.watch(xboardServiceProvider);
    final current = _current;
    final session = ref.watch(commissionSessionProvider);
    xbListenForReadRecovery(context, ref, () {
      if (!_current || _submitting || _unconfirmed ||
          session.pendingOperation != null) {
        return;
      }
      _recoveryPending = true;
      _drainRecovery();
    });
    if (current && session.pendingOperation != null) {
      return CommissionPendingReview(owner: widget.owner, session: session);
    }
    // Grow margins more slowly than the viewport, so a wider phone never
    // has less usable width. Both ends retain comfortable minimum padding.
    final space = ((MediaQuery.sizeOf(context).width - 320) / 240)
        .clamp(0.0, 1.0).toDouble();
    final inner = 12 + 12 * space;
    return PopScope(
      canPop: !_submitting || !current,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: AlertDialog(
        backgroundColor: XbTokens.of(context).sf2,
        insetPadding: EdgeInsets.symmetric(horizontal: 10 + 30 * space, vertical: 10 + 14 * space),
        titlePadding: EdgeInsets.fromLTRB(inner, 14 + 10 * space, inner, 0),
        contentPadding: EdgeInsets.fromLTRB(inner, 8 + 12 * space, inner, 0),
        actionsPadding: EdgeInsets.fromLTRB(inner, 8 + 8 * space, inner, inner),
        scrollable: true,
        title: const Text('佣金提现', textAlign: TextAlign.center),
        content: !current
            ? const Text('账号状态已变化，请关闭后重新检测。')
            : _form
            ? _applicationForm(context, space)
            : _preflight(context, space),
        actions: [
          if (current && (!_form || !_unconfirmed))
            XbPurchaseActions(
              labelSize: _form ? 15 : 13,
              cancelLabel: _form ? '取消' : '关闭',
              onCancel: _submitting ? null : _close,
              confirmLabel: !_form ? '提交提现申请' : '提交申请',
              busyLabel: _submitting ? '正在提交提现申请…'
                  : !_form && _checking ? '正在核对提现条件…'
                  : _form && _methodsChecking ? '正在读取收款方式…' : null,
              onConfirm: !_form ? (_eligible ? _continue : null) : (_canSubmit ? _submit : null),
            )
          else
            TextButton(onPressed: _close, child: const Text('关闭')),

        ],
      ),
    );
  }

  Widget _preflight(BuildContext context, double space) {
    final balance = _balanceCents;
    final records = _paidRecords;
    final muted = XbTokens.of(context).onv;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Text('满足两项条件后可提交申请',
          style: TextStyle(fontSize: 13, color: muted))),
        SizedBox(height: 8 + 4 * space),
        _amountRow(context, '可用佣金', balance, prominent: true),
        SizedBox(height: 4 + 8 * space),
        _condition(
          context,
          space: space,
          label: '可用佣金 ≥ ¥${withdrawMinimumCents ~/ 100}',
          checking: _balanceChecking,
          known: balance != null,
          passed: balance != null && balance >= withdrawMinimumCents,
        ),
        Divider(height: 1, thickness: 1, color: XbTokens.of(context).line),
        _condition(
          context,
          space: space,
          label: '成功邀请 ≥$withdrawMinimumPaidRecords 次',
          checking: _recordsChecking,
          unknownLabel: '读取失败',
          known: records != null,
          value: records == null
              ? null
              : records >= withdrawMinimumPaidRecords
              ? '至少 $withdrawMinimumPaidRecords 次'
              : '$records 次',
          passed: records != null && records >= withdrawMinimumPaidRecords,
        ),
        SizedBox(height: 8 + 4 * space),
        Text(_checking ? '正在检测提现条件…' : balance == null || records == null ? '暂时无法核实提现条件。' : _eligible ? '两项条件均已满足。' : '暂未满足提现条件。',
          style: TextStyle(fontSize: 12, color: muted)),
        if (!_checking && (balance == null || records == null))
          ...[
            if (xbIsRecoverableReadError(_balanceError) || xbIsRecoverableReadError(_recordsError))
              const Text('网络暂时不可用，恢复连接后会重新核对失败项。'),
            TextButton(onPressed: () => _checkEligibility(), child: const Text('重新检测')),
          ],
        const SizedBox(height: 8),
        Text('提现前请先联系在线客服。提交后由人工审核。',
          style: TextStyle(fontSize: 12, color: muted)),
      ],
    );
  }

  Widget _condition(
    BuildContext context, {
    required double space,
    required String label,
    required bool checking,
    required bool known,
    String? value,
    String unknownLabel = '无法核实',
    required bool passed,
  }) {
    final t = XbTokens.of(context);
    final (icon, color, status) = checking
        ? (Icons.more_horiz, t.onv, '检测中…')
        : !known
        ? (Icons.info_outline, t.onv, unknownLabel)
        : passed
        ? (Icons.check_circle, XbTokens.ok, '已达标')
        : (Icons.cancel, XbTokens.bad, '未达标');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6 + 3 * space),
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: const {
          0: FlexColumnWidth(),
          1: FixedColumnWidth(5),
          2: MinColumnWidth(IntrinsicColumnWidth(), FractionColumnWidth(.5)),
        },
        children: [
          TableRow(children: [
            Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 5),
                Flexible(child: Text(label, style: TextStyle(fontSize: 12, color: t.on))),
              ],
            ),
            const SizedBox.shrink(),
            Text(
              value != null && known && !checking ? '$value · $status' : status,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 11, color: t.onv),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _amountRow(
    BuildContext context,
    String label,
    int? cents, {
    bool prominent = false,
  }) {
    final t = XbTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
      decoration: BoxDecoration(
        color: t.sfc,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: prominent ? null : Border.all(color: t.line, width: 1.5),
      ),
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: const {
          0: FlexColumnWidth(),
          1: FixedColumnWidth(8),
          // Reserve the natural amount width first. Only an exceptionally long
          // amount needs to wrap; never scale the user's text to fit.
          2: MinColumnWidth(IntrinsicColumnWidth(), FractionColumnWidth(.82)),
        },
        children: [
          TableRow(children: [
            Text(label, textAlign: TextAlign.start, style: TextStyle(fontSize: 13, color: t.onv)),
            const SizedBox.shrink(),
            Text(
              cents == null ? '—' : xbYuan(cents / 100),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: prominent ? 21 : 14,
                fontWeight: FontWeight.w700,
                color: t.on,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _applicationForm(BuildContext context, double space) {
    final editing = !_submitting && !_unconfirmed;
    final t = XbTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '佣金整笔提现，不可拆分。到账以审核和收款渠道处理结果为准，提交不代表已打款。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, height: 1.4, color: t.onv),
        ),
        SizedBox(height: 8 + 4 * space),
        _amountRow(context, '整笔提现额', _balanceCents),
        SizedBox(height: 8 + 4 * space),
        if (!_methodsChecking && _methods.isEmpty) ...[
          Text(xbIsRecoverableReadError(_methodsError)
              ? '网络异常，暂时无法核实可用收款方式。' : '暂时无法核实可用收款方式。'),
          TextButton(onPressed: _loadMethods, child: const Text('重试')),
        ] else if (!_methodsChecking) ...[
          _payoutField(context, '收款方式',
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _method,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.on, fontSize: 13),
                hint: Text('请选择收款方式',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.onv, fontSize: 13)),
                isExpanded: true,
                isDense: false,
                onChanged: editing
                    ? (method) => setState(() {
                        _method = method;
                        _confirmed = false;
                      })
                    : null,
                items: [
                  for (final method in _methods)
                    DropdownMenuItem(value: method, child: Text(method)),
                ],
              ),
            ),
          ),
          SizedBox(height: 8 + 4 * space),
          _payoutField(context, '收款账户', child: TextField(
            controller: _account,
            enabled: editing,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(color: t.on, fontSize: 14),
            decoration: InputDecoration(
              isDense: true, filled: false,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              hintText: '请输入收款账户',
              hintStyle: TextStyle(color: t.onv, fontSize: 13),
              border: InputBorder.none, enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
            ),
            onChanged: (_) => setState(() => _confirmed = false),
          )),
          if (_method == '支付宝')
            const Text('支付宝提现请联系在线客服提供收款码。'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('确认收款方式和账户真实、准确'),
            value: _confirmed,
            onChanged: editing && _hasDetails
                ? (value) => setState(() => _confirmed = value ?? false)
                : null,
          ),
        ],
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 15, color: t.onv),
          const SizedBox(width: 6),
          Expanded(child: Text(
            '提现门槛 ¥${withdrawMinimumCents ~/ 100}，申请由人工审核。',
            style: TextStyle(fontSize: 12, height: 1.4, color: t.onv),
          )),
        ]),
        if (_unconfirmed)
          const Text('申请结果尚未确认。请先核对余额和记录，或联系在线客服，勿重复提交。'),
      ],
    );
  }

  Widget _payoutField(BuildContext context, String label, {required Widget child}) {
    final t = XbTokens.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: t.sfc,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: Border.all(color: t.line, width: 1.5),
      ),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 13, color: t.onv)),
        const SizedBox(width: 8),
        Expanded(child: Semantics(label: label, child: child)),
      ]),
    );
  }
}
