import 'package:material_ui/material_ui.dart';

import 'xb_theme.dart';
import 'xb_plan_details.dart' show XbPlanComparison;
import 'xb_ui_kit.dart' show XbGradientAction;

/// Shared footer for the renewal and traffic-reset notices. Uses the same
/// brand gradient as other primary actions, not an independently darkened tint.
class XbPurchaseActions extends StatelessWidget {
  const XbPurchaseActions({super.key, required this.confirmLabel, required this.onConfirm,
    required this.onCancel, this.cancelLabel = '再想想', this.labelSize = 13, this.busyLabel});
  final String confirmLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final String cancelLabel;
  final double labelSize;
  final String? busyLabel;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final label = TextStyle(fontSize: labelSize, fontWeight: FontWeight.w600);
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: FilledButton(
        onPressed: onCancel,
        style: FilledButton.styleFrom(backgroundColor: Color.lerp(t.sf2, t.sfc, 0.64),
          foregroundColor: t.on, minimumSize: const Size(0,46), elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(XbTokens.rMd))),
        child: Text(cancelLabel, textAlign: TextAlign.center, style: label),
      )),
      const SizedBox(width: 8),
      Expanded(child: XbGradientAction(onPressed: onConfirm,
        busyLabel: busyLabel,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(confirmLabel, textAlign: TextAlign.center,
          style: label.copyWith(color: onConfirm == null ? t.onv : Colors.white)))),
    ]));
  }
}

class XbPlanConfirmation extends StatelessWidget {
  const XbPlanConfirmation({super.key, required this.planName, required this.confirmLabel, this.targetName});
  final String planName;
  final String? targetName;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final renew = targetName == null;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [Expanded(child: Text(label, style: TextStyle(color: t.onv, fontSize: 13))),
        const SizedBox(width: 8), Flexible(child: Text(value, textAlign: TextAlign.end,
          style: TextStyle(color: t.on, fontSize: 13, fontWeight: FontWeight.w700)))]));
    return AlertDialog(scrollable: true, backgroundColor: t.sf2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      titlePadding: const EdgeInsets.fromLTRB(18,22,18,0),
      contentPadding: const EdgeInsets.fromLTRB(18,15,18,0),
      actionsPadding: const EdgeInsets.fromLTRB(18,16,18,18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(XbTokens.rLg+6)),
      title: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(renew ? '确认续费相同套餐' : '确认更换套餐', textAlign: TextAlign.center, style: TextStyle(color:t.on,fontSize:19,fontWeight:FontWeight.w700)),
        const SizedBox(height:6),
        Text(renew ? '当前的$planName仍在有效期内。' : '当前套餐「$planName」尚未到期。', textAlign: TextAlign.center, style:TextStyle(color:t.onv,fontSize:13,height:1.4)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (!renew) ...[XbPlanComparison(current: planName, target: targetName!), const SizedBox(height: 8)],
        Container(padding:const EdgeInsets.symmetric(horizontal:10), decoration:BoxDecoration(
          color:Color.lerp(t.sf2,t.sfc,0.64),borderRadius:BorderRadius.circular(XbTokens.rMd)),
          child:Column(children:[row('已用流量',renew ? '不会改变' : '清零'),Divider(height:1,thickness:1,color:t.line),row('套餐时长',renew ? '按购买周期增加' : '按购买周期重新计算')])),
        const SizedBox(height:11),
        Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(renew ? Icons.event_repeat_outlined : Icons.warning_amber_rounded,size:16,color:t.onv),
          const SizedBox(width:6),Expanded(child: Text.rich(TextSpan(style:TextStyle(color:t.onv,fontSize:12,height:1.55),children:[
            if (!renew) const TextSpan(text: '更换会'),
            TextSpan(text:renew ? '流量重置日不变。' : '覆盖现有套餐',style:TextStyle(color:t.on,fontWeight:FontWeight.w700)),
            TextSpan(text:renew ? '到了重置日会自动重置流量。' : '，剩余流量和有效期不会保留。'),])))]),
      ]),
      actions:[XbPurchaseActions(confirmLabel:confirmLabel,onCancel:()=>Navigator.of(context).pop(false),onConfirm:()=>Navigator.of(context).pop(true))]);
  }
}
