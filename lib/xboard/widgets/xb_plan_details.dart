import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../models/plan_item.dart';
import '../providers/xboard_providers.dart';
import '../util/html_link.dart';
import '../util/html_text.dart';
import 'xb_html_contrast.dart';
import 'xb_emoji_text.dart';
import 'xb_theme.dart';

/// Catalog facts shown identically in the shop and before checkout.
class XbPlanDetails extends ConsumerWidget {
  const XbPlanDetails({super.key, required this.plan, this.showQuota = true, this.compact = false, this.tightDescription = false});

  final PlanItem plan;
  final bool showQuota;
  final bool compact;
  final bool tightDescription;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final description = plan.description?.trim() ?? '';
    final hasQuota = showQuota && plan.transferEnableGb > 0;
    if (!hasQuota && description.isEmpty) return const SizedBox.shrink();
    final t = XbTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: compact ? 4 : 8),
        Divider(color: t.hair, height: compact ? 1 : null),
        if (compact) const SizedBox(height: 4),
        if (hasQuota)
          Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Icon(Icons.data_usage, size: 16, color: t.onv),
                ),
                TextSpan(text: '  ${plan.transferEnableGb} GB'),
              ],
            ),
          ),
        if (description.isNotEmpty)
          Html(
            data: wrapEmojiForHtml(description),
            extensions: [
              XbHtmlContrastExtension(background: t.card, foreground: t.on),
            ],
            style: {
              'body': Style(
                margin: Margins.zero,
                padding: HtmlPaddings.zero,
                color: t.on,
                lineHeight: tightDescription ? const LineHeight(1.35) : null,
              ),
              if (compact) 'p': Style(margin: Margins.only(bottom: tightDescription ? 2 : 4)),
              if (tightDescription) ...{
                for (final tag in ['ul', 'ol']) tag: Style(margin: Margins.zero),
                'li': Style(margin: Margins.only(bottom: 2)),
              },
              '.$kXbEmojiClass': Style(fontFamily: 'Twemoji'),
            },
            onLinkTap: (url, _, _) =>
                openHtmlLink(url, base: ref.read(apiEndpointProvider)),
          ),
      ],
    );
  }
}

/// The same comparison is shown both on store entry and during order preflight.
class XbPlanComparison extends StatelessWidget {
  const XbPlanComparison({super.key, required this.current, required this.target});

  final String current;
  final String target;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    final inset = Color.lerp(t.sf2, t.sfc, 0.64)!;
    Widget card(String label, String name, Color fill, Color ink) => Expanded(
      child: Container(
        constraints: const BoxConstraints(minHeight: 51),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(XbTokens.rSm)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(color: t.onv, fontSize: 11)),
          const SizedBox(height: 2),
          XbEmojiText(name, textAlign: TextAlign.center,
              style: TextStyle(color: ink, fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
    return Row(children: [
      card('当前', current, inset, t.on),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 7), child: Icon(Icons.arrow_forward_rounded, size: 16, color: t.onv)),
      card('更换为', target, Color.lerp(inset, brand, .08)!,
          Theme.of(context).brightness == Brightness.dark ? Color.lerp(brand, t.on, .4)! : brand),
    ]);
  }
}
