import 'package:material_ui/material_ui.dart';
import 'xb_theme.dart' show XbTokens;

/// Shared presentation for expiry and traffic notices, including desktop fit-content.
class XbPlanNoticeCard extends StatelessWidget {
  const XbPlanNoticeCard({
    super.key,
    required this.title,
    required this.desc,
    required this.icon,
    required this.urgent,
    required this.actionLabel,
    this.onTap,
    this.centered = false,
  });
  final String title, desc, actionLabel;
  final IconData icon;
  final bool urgent, centered;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = XbTokens.of(context);
    final accent = urgent ? XbTokens.bad : XbTokens.warn;
    final textCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: t.on,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          desc,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );

    final card = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(XbTokens.rMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        child: Ink(
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              accent.withValues(alpha: 0.10),
              scheme.surface,
            ),
            border: Border.all(color: accent.withValues(alpha: 0.32)),
            borderRadius: BorderRadius.circular(XbTokens.rMd),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            child: Row(
              // 桌面 fit-content → min（横幅按内容收窄）；移动全宽 → max。
              mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
              children: [
                // 图标方块
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(XbTokens.rSm),
                  ),
                  child: Icon(icon, size: 19, color: accent),
                ),
                const SizedBox(width: 11),
                // 标题 + 描述：全宽态 Expanded（把按钮顶到右缘）；居中态 Flexible（按内容收窄）。
                centered
                    ? Flexible(fit: FlexFit.loose, child: textCol)
                    : Expanded(child: textCol),
                const SizedBox(width: 10),
                // 去续费按钮
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(XbTokens.rSm),
                  ),
                  child: Text(
                    actionLabel,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: centered ? Align(alignment: Alignment.center, child: card) : card,
    );
  }
}
