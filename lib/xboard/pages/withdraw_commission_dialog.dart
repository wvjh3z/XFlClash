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
    return PopScope(
      canPop: !_submitting || !current,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: AlertDialog(
        backgroundColor: XbTokens.of(context).sf2,
        scrollable: true,
        title: const Text('佣金提现'),
        content: !current
            ? const Text('账号状态已变化，请关闭后重新检测。')
            : _form
            ? _applicationForm(context)
            : _preflight(context),
        actions: [
          TextButton(
            onPressed: _submitting && current ? null : _close,
            style: _form && !_unconfirmed ? TextButton.styleFrom(backgroundColor: XbTokens.of(context).sfc, foregroundColor: XbTokens.of(context).on) : null,
            child: Text(_form && !_unconfirmed ? '取消' : '关闭'),
          ),
          if (current && !_form) ...[
            if (!_checking && (_balanceCents == null || _paidRecords == null))
              TextButton(
                onPressed: _checkEligibility,
                child: const Text('重新检测'),
              ),
            FilledButton(
              onPressed: _eligible ? _continue : null,
              child: const Text('填写收款资料'),
            ),
          ],
          if (current && _form && !_unconfirmed)
            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: Text(_submitting ? '提交中…' : '提交申请'),
            ),
        ],
      ),
    );
  }

  Widget _preflight(BuildContext context) {
    final balance = _balanceCents;
    final records = _paidRecords;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('满足两项条件后可提交申请。'),
        const SizedBox(height: 12),
        _condition(
          context,
          label: '可用佣金 ≥ ¥${withdrawMinimumCents ~/ 100}',
          checking: _balanceChecking,
          value: balance == null ? null : xbYuan(balance / 100),
          passed: balance != null && balance >= withdrawMinimumCents,
        ),
        _condition(
          context,
          label: '成功邀请 ≥$withdrawMinimumPaidRecords 次',
          checking: _recordsChecking,
          value: records == null
              ? null
              : records >= withdrawMinimumPaidRecords
              ? '至少 $withdrawMinimumPaidRecords 次'
              : '$records 次',
          passed: records != null && records >= withdrawMinimumPaidRecords,
        ),
        const SizedBox(height: 12),
        const Text('提现前请联系在线客服。申请提交后需人工审核。'),
      ],
    );
  }

  Widget _condition(
    BuildContext context, {
    required String label,
    required bool checking,
    required String? value,
    required bool passed,
  }) {
    final text = Theme.of(context).textTheme;
    final icon = checking
        ? Icons.more_horiz
        : passed
        ? Icons.check_circle_outline
        : Icons.info_outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: passed ? XbTokens.ok : null),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.titleSmall),
                Text(
                  checking
                      ? '检测中…'
                      : value == null
                      ? '无法核实'
                      : '$value · ${passed ? '已达标' : '未达标'}',
                  style: text.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _applicationForm(BuildContext context) {
    final systemText = Theme.of(context).textTheme;
    final editing = !_submitting && !_unconfirmed;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '整笔可用佣金（当前）：${xbYuan(_balanceCents! / 100)}',
          style: systemText.titleSmall,
        ),
        const Text('佣金整笔提现，不可拆分。申请由人工审核，到账时间以审核和收款渠道处理结果为准，提交不代表已打款。'),
        const SizedBox(height: 12),
        if (_methodsChecking)
          const LinearProgressIndicator()
        else if (_methods.isEmpty) ...[
          const Text('暂时无法核实可用收款方式。'),
          TextButton(onPressed: _loadMethods, child: const Text('重试')),
        ] else ...[
          InputDecorator(
            decoration: const InputDecoration(labelText: '收款方式'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _method,
                hint: const Text('请选择'),
                isExpanded: true,
                isDense: true,
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
          const SizedBox(height: 12),
          TextField(
            controller: _account,
            enabled: editing,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '收款账户'),
            onChanged: (_) => setState(() => _confirmed = false),
          ),
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
        if (_unconfirmed)
          const Text('申请结果尚未确认。请先核对余额和记录，或联系在线客服，勿重复提交。'),
      ],
    );
  }
}
