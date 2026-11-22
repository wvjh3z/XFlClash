import 'package:material_ui/material_ui.dart';

import '../models/confirmed_order.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbShowDialog;
import 'sentry_bootstrap.dart';

export '../models/confirmed_order.dart';

/// Shared by regular checkout and traffic reset. Only a non-null trade number
/// allows the caller to open payment. A declined dialog performs no write.
Future<XbResult<String?>> submitConfirmedOrder({
  required BuildContext context,
  required XboardService service,
  required bool Function() isActive,
  required ConfirmedOrderQuote quote,
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
    return await (control as XboardConfirmedOrderControl).confirmOrder(
      quote,
      isActive: current,
      confirm: (conflict) async {
        if (!current()) return false;
        final accepted = await xbShowDialog<bool>(
          context: context,
          brandColor: xbBrandColor(),
          builder: (_) => _ExistingOrderDialog(conflict),
        );
        return current() && accepted == true;
      },
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

class _ExistingOrderDialog extends StatelessWidget {
  const _ExistingOrderDialog(this.conflict);

  final ConfirmedOrderConflict conflict;

  @override
  Widget build(BuildContext context) {
    final replace = conflict.choice == ConfirmedOrderChoice.replaceExisting;
    final due = xbYuan(conflict.existingPayableCents / 100);
    final estimate = xbYuan(conflict.quote.estimatedCents / 100);
    final theme = Theme.of(context);
    Widget comparison(String label, String plan, String detail) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
        const SizedBox(width: 8),
        Flexible(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(plan, textAlign: TextAlign.end, style: theme.textTheme.titleSmall),
          Text(detail, textAlign: TextAlign.end, style: theme.textTheme.bodySmall),
        ])),
      ]),
    );
    return AlertDialog(
      title: Text(replace ? '已有待支付订单' : '继续支付已有订单？'),
      scrollable: true,
      content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(replace ? '本次选择与原订单不同' : '套餐和周期相同，请核对旧单应付金额。'),
          const SizedBox(height: 8),
          comparison('待支付订单', conflict.existingPlanName, '${planPeriodLabel(conflict.existingPeriod)} · $due'),
          const Divider(height: 1),
          comparison(replace ? '本次下单' : '本次结算', conflict.quote.planName, '${planPeriodLabel(conflict.quote.period)} · 当前预估 $estimate'),
          Text('旧订单号：${conflict.existingTradeNo}（以上不含支付手续费）', style: theme.textTheme.bodySmall),
          if (conflict.existingCreditCents > 0) Text('旧单已抵扣 ${xbYuan(conflict.existingCreditCents / 100)}'),
          const SizedBox(height: 12),
          Text(
            replace
                ? '确认后会先取消旧单，再提交新订单。返回会保留旧单。'
                : '继续支付会使用已有订单的金额，不会重新下单。',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(replace ? '再想想' : '返回结算'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(replace ? '取消旧单并下单' : '支付已有订单 $due'),
        ),
      ],
    );
  }
}
