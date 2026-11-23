import 'package:material_ui/material_ui.dart';

import '../models/confirmed_order.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbShowDialog, XbTokens;
import '../widgets/xb_ui_kit.dart' show XbGradientAction;
import 'sentry_bootstrap.dart';

export '../models/confirmed_order.dart';

/// Shared by regular checkout and traffic reset. Only a non-null trade number
/// allows the caller to open payment. A declined dialog performs no write.
Future<XbResult<String?>> submitConfirmedOrder({
  required BuildContext context,
  required XboardService service,
  required bool Function() isActive,
  required ConfirmedOrderQuote quote,
  void Function(ConfirmedOrderStage stage)? onStage,
}) async {
  final route = ModalRoute.of(context);
  bool current() => context.mounted && (route?.isActive ?? true) && isActive();
  if (!current()) return const XbSuccess(null);
  final control = service;
  if (control is! XboardConfirmedOrderControl) {
    return const XbFailure(
      XbUnexpected('confirmOrder', '无法核对订单，暂不能提交。'),
    );
  }
  try {
    Future<bool> ask(ConfirmedOrderConflict conflict) async {
      if (!current()) return false;
      final accepted = await xbShowDialog<bool>(
        context: context,
        brandColor: xbBrandColor(),
        builder: (_) => _ExistingOrderDialog(conflict),
      );
      return current() && accepted == true;
    }
    if (control is XboardProgressOrderControl && onStage != null) {
      return await (control as XboardProgressOrderControl).confirmOrder(
        quote, isActive: current, confirm: ask,
        onStage: (stage) { if (current()) onStage(stage); },
      );
    }
    return await (control as XboardConfirmedOrderControl).confirmOrder(
      quote,
      isActive: current,
      confirm: ask,
    );
  } catch (error, stack) {
    if (!current()) return const XbSuccess(null);
    SentryBootstrap.captureException(
      error,
      stackTrace: stack,
      where: 'confirmed order',
    );
    return const XbFailure(
      XbUnconfirmed('confirmOrder', '订单结果尚未确认，请先在“我的订单”核对。'),
    );
  }
}

class _ExistingOrderDialog extends StatefulWidget {
  const _ExistingOrderDialog(this.conflict);

  final ConfirmedOrderConflict conflict;

  @override
  State<_ExistingOrderDialog> createState() => _ExistingOrderDialogState();
}

class _ExistingOrderDialogState extends State<_ExistingOrderDialog> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflict;
    final replace = conflict.choice == ConfirmedOrderChoice.replaceExisting;
    final due = xbYuan(conflict.existingPayableCents / 100);
    final estimate = xbYuan(conflict.quote.estimatedCents / 100);
    final balance = conflict.existingBalanceCents;
    final surplus = conflict.existingAppliedSurplusCents;
    final t = XbTokens.of(context);
    final note = TextStyle(color: t.onv, fontSize: 13, height: 1.4);
    final fine = TextStyle(color: t.onv, fontSize: 12, height: 1.4);
    const buttonText = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 6);
    Widget comparison(String label, String plan, String detail) => Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Text(label, style: fine.copyWith(color: t.on))),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(plan, textAlign: TextAlign.right,
                style: TextStyle(color: t.on, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(detail, textAlign: TextAlign.right, style: fine),
          ],
        )),
      ],
    );
    const title = '已有待支付订单';
    return Dialog(
      backgroundColor: t.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(XbTokens.rMd)),
      constraints: const BoxConstraints(maxWidth: 303),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Semantics(namesRoute: true, header: true, child: Text(title, textAlign: TextAlign.center,
                  style: TextStyle(color: t.on, fontSize: 18, fontWeight: FontWeight.w700))),
              const SizedBox(height: 10),
              Text(replace ? '本次选择与原订单不同' : '套餐和周期相同，但金额不同。',
                  textAlign: TextAlign.start, style: note),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.sf,
                  border: Border.all(color: t.line),
                  borderRadius: BorderRadius.circular(XbTokens.rMd),
                ),
                child: Column(children: [
                  comparison('待支付订单', conflict.existingPlanName,
                      '${planPeriodLabel(conflict.existingPeriod)} · $due'),
                  Divider(height: 17, thickness: 1, color: t.line),
                  comparison(replace ? '本次下单' : '本次结算', conflict.quote.planName,
                      '${planPeriodLabel(conflict.quote.period)} · ${replace ? '' : '当前预估 '}$estimate'),
                ]),
              ),
              const SizedBox(height: 10),
              Text(replace ? '确认后，将取消原订单，按本次选择重新下单。'
                  : '将按旧单金额 $due 继续支付，不会创建新订单。', style: note),
              if (balance > 0 || surplus != 0) Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: t.onv,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    minimumSize: const Size(0, 32), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16),
                label: Text(_expanded ? '收起订单明细' : '查看订单明细', style: fine),
              )),
              if (_expanded) ...[
                Text('旧订单号', style: fine),
                SelectableText(conflict.existingTradeNo, style: fine),
                if (balance > 0)
                  Text('账户余额已抵扣 ${xbYuan(balance / 100)}', style: fine),
                if (surplus != null && surplus > 0)
                  Text('旧套餐结余已抵扣 ${xbYuan(surplus / 100)}', style: fine),
                if (surplus == null)
                  Text('部分抵扣明细待核实。', style: fine),
                Text('本次金额为预估；以上金额均不含支付手续费。', style: fine),
              ],
            ]),
          )),
          const SizedBox(height: 16),
          IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: t.onv, side: BorderSide(color: t.line),
                  minimumSize: const Size(0, 44), padding: buttonPadding,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(replace ? '再想想' : '返回结算', textAlign: TextAlign.center, style: buttonText),
            )),
            const SizedBox(width: 8),
            Expanded(child: XbGradientAction(height: 44, padding: buttonPadding,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(replace ? '取消旧单并下单' : '继续支付旧单',
                  textAlign: TextAlign.center, style: buttonText),
            )),
          ])),
        ]),
      ),
    );
  }
}
