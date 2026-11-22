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
  const XbPlanDetails({super.key, required this.plan});

  final PlanItem plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final description = plan.description?.trim() ?? '';
    final hasQuota = plan.transferEnableGb > 0;
    if (!hasQuota && description.isEmpty) return const SizedBox.shrink();
    final t = XbTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Divider(color: t.hair),
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
              ),
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
    Widget card(String label, String name, Color fill, Color ink) => Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(XbTokens.rMd)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            XbEmojiText(name, style: TextStyle(color: ink, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
    return Row(children: [
      card('当前', current, t.sfc, t.on),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward_rounded, size: 18, color: t.onv)),
      card('更换为', target, brand.withValues(alpha: 0.10), brand),
    ]);
  }
}
