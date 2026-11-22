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
  bool _balanceChecking = true;
  bool _recordsChecking = true;
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

  void _checkEligibility() {
    if (!_current || _form) return;
    final generation = ++_generation;
    setState(() {
      _balanceChecking = true;
      _recordsChecking = true;
      _balanceCents = null;
      _paidRecords = null;
    });
    bool active() => _current && generation == _generation && !_form;
    unawaited(_checkBalance(active));
    unawaited(_checkRecords(active));
  }

  Future<void> _checkBalance(bool Function() active) async {
    int? cents;
    try {
      // Read directly from the service, not the painted card or inviteInfoProvider
      // (the provider may generate an invitation code as a side effect).
      final result = await _withValidity(active, widget.owner.getInviteInfo);
      if (result case XbSuccess(:final data)) {
        cents = withdrawBalanceCents(data.commissionBalanceYuan);
      }
    } catch (_) {
      // Unknown is not a zero balance.
    }
    if (!active()) return;
    setState(() {
      _balanceChecking = false;
      _balanceCents = cents;
    });
  }

  Future<void> _checkRecords(bool Function() active) async {
    int? count;
    try {
      final result = await _withValidity(
        active,
        () => widget.owner.getCommissionRecords(
          page: 1,
          pageSize: withdrawMinimumPaidRecords,
        ),
      );
      if (result case XbSuccess(:final data)) {
        count = withdrawPaidRecordCount(data);
      }
    } catch (_) {
      // Unknown is not zero records and cannot pass the gate.
    }
    if (!active()) return;
    setState(() {
      _recordsChecking = false;
      _paidRecords = count;
    });
  }

  void _continue() {
    if (!_current || !_eligible || _form) return;
    setState(() => _form = true);
    unawaited(_loadMethods());
  }

  Future<void> _loadMethods() async {
    if (!_current || !_form || _methodsChecking) return;
    final generation = ++_generation;
    setState(() {
      _methodsChecking = true;
      _methods = const [];
      _method = null;
      _confirmed = false;
    });
    bool active() => _current && _form && generation == _generation;
    List<String> methods = const [];
    try {
      final result = await _withValidity(active, widget.owner.getWithdrawMethods);
      if (result case XbSuccess(:final data)) {
        methods = data
            .where((method) => method.trim().isNotEmpty)
            .toSet()
            .toList();
      }
    } catch (_) {
      // No guessed payout method when the server list cannot be verified.
    }
    if (!active()) return;
    setState(() {
      _methods = methods;
      _methodsChecking = false;
    });
  }

  Future<void> _submit() async {
    if (!_current || !_canSubmit) return;
    final method = _method!;
    final account = _account.text.trim();
    setState(() => _submitting = true);
    try {
      final result = await _withValidity(
        () => _current && _submitting,
        () => widget.owner.withdrawCommission(method: method, account: account),
      );
      if (!_current) return;
      switch (result) {
        case XbSuccess(data: true):
          xbToastSafe('提现申请已提交，请等待人工审核。');
          _close();
        case XbSuccess():
        case XbFailure(error: XbUnconfirmed()):
          _showUnconfirmed();
        case XbFailure(:final error):
          xbToastSafe(resolveErrorText(error, fallback: '提现失败，请重试'));
      }
    } catch (_) {
      if (_current) _showUnconfirmed();
    } finally {
      if (_current) setState(() => _submitting = false);
    }
  }

  void _showUnconfirmed() {
    ref.invalidate(inviteInfoProvider);
    ref.invalidate(commissionRecordsProvider);
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
    final compact = MediaQuery.sizeOf(context).width < 360;
    return PopScope(
      canPop: !_submitting || !current,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: AlertDialog(
        backgroundColor: XbTokens.of(context).sf2,
        insetPadding: compact ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10) : null,
        titlePadding: compact ? const EdgeInsets.fromLTRB(12, 14, 12, 0) : null,
        contentPadding: compact ? const EdgeInsets.fromLTRB(12, 8, 12, 0) : null,
        actionsPadding: compact ? const EdgeInsets.fromLTRB(12, 8, 12, 12) : null,
        scrollable: true,
        title: const Text('佣金提现', textAlign: TextAlign.center),
        content: !current
            ? const Text('账号状态已变化，请关闭后重新检测。')
            : _form
            ? _applicationForm(context, compact: compact)
            : _preflight(context, compact: compact),
        actions: [
          if (current && (!_form || !_unconfirmed))
            XbPurchaseActions(
              cancelLabel: _form ? '取消' : '关闭',
              onCancel: _submitting ? null : _close,
              confirmLabel: !_form ? '提交提现申请' : _submitting ? '提交中…' : '提交申请',
              onConfirm: !_form ? (_eligible ? _continue : null) : (_canSubmit ? _submit : null),
            )
          else
            TextButton(onPressed: _close, child: const Text('关闭')),

        ],
      ),
    );
  }

  Widget _preflight(BuildContext context, {required bool compact}) {
    final balance = _balanceCents;
    final records = _paidRecords;
    final muted = XbTokens.of(context).onv;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Text('满足两项条件后可提交申请',
          style: TextStyle(fontSize: 13, color: muted))),
        SizedBox(height: compact ? 8 : 12),
        _amountRow(context, '可用佣金', balance, prominent: true),
        SizedBox(height: compact ? 4 : 12),
        _condition(
          context,
          compact: compact,
          label: '可用佣金 ≥ ¥${withdrawMinimumCents ~/ 100}',
          checking: _balanceChecking,
          known: balance != null,
          passed: balance != null && balance >= withdrawMinimumCents,
        ),
        Divider(height: 1, thickness: 1, color: XbTokens.of(context).hair),
        _condition(
          context,
          compact: compact,
          label: '成功邀请 ≥$withdrawMinimumPaidRecords 次',
          checking: _recordsChecking,
          known: records != null,
          value: records == null
              ? null
              : records >= withdrawMinimumPaidRecords
              ? '至少 $withdrawMinimumPaidRecords 次'
              : '$records 次',
          passed: records != null && records >= withdrawMinimumPaidRecords,
        ),
        SizedBox(height: compact ? 8 : 12),
        Text(_checking ? '正在检测提现条件…' : balance == null || records == null ? '暂时无法核实提现条件。' : _eligible ? '两项条件均已满足。' : '暂未满足提现条件。',
          style: TextStyle(fontSize: 12, color: muted)),
        if (!_checking && (balance == null || records == null))
          TextButton(onPressed: _checkEligibility, child: const Text('重新检测')),
        const SizedBox(height: 8),
        Text('提现前请先联系在线客服。提交后由人工审核。',
          style: TextStyle(fontSize: 12, color: muted)),
      ],
    );
  }

  Widget _condition(
    BuildContext context, {
    required bool compact,
    required String label,
    required bool checking,
    required bool known,
    String? value,
    required bool passed,
  }) {
    final t = XbTokens.of(context);
    final (icon, color, status) = checking
        ? (Icons.more_horiz, t.onv, '检测中…')
        : !known
        ? (Icons.info_outline, t.onv, '无法核实')
        : passed
        ? (Icons.check_circle, XbTokens.ok, '已达标')
        : (Icons.cancel, XbTokens.bad, '未达标');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 9),
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

  Widget _applicationForm(BuildContext context, {required bool compact}) {
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
        SizedBox(height: compact ? 8 : 12),
        _amountRow(context, '提现金额（整笔佣金）', _balanceCents),
        SizedBox(height: compact ? 8 : 12),
        if (_methodsChecking)
          const LinearProgressIndicator()
        else if (_methods.isEmpty) ...[
          const Text('暂时无法核实可用收款方式。'),
          TextButton(onPressed: _loadMethods, child: const Text('重试')),
        ] else ...[
          _payoutField(context, '收款方式',
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _method,
                style: TextStyle(color: t.on, fontSize: 13),
                hint: Text('请选择收款方式',
                  style: TextStyle(color: t.onv, fontSize: 13)),
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
          SizedBox(height: compact ? 8 : 12),
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
      ),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 13, color: t.onv)),
        const SizedBox(width: 8),
        Expanded(child: Semantics(label: label, child: child)),
      ]),
    );
  }
}
