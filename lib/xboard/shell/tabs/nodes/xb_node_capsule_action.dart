import 'package:material_ui/material_ui.dart';
import 'package:prism_ui/prism_ui.dart' show AppRadius, AppTextStyle;

import '../../../../ui/icons/icons.dart' show Glyph, GlyphIcon;
import '../../../widgets/xb_theme.dart' show XbTokens;

/// One independently focusable and clipped action in the mobile node toolbar.
class XbNodeCapsuleAction extends StatefulWidget {
  const XbNodeCapsuleAction({
    super.key,
    required this.surfaceKey,
    required this.glyph,
    required this.iconSize,
    required this.label,
    required this.description,
    required this.onTap,
    this.busy = false,
    this.cooling = false,
    this.countdownSeconds,
  });

  final Key surfaceKey;
  final Glyph glyph;
  final double iconSize;
  final String label;
  final String description;
  final VoidCallback? onTap;
  final bool busy;
  final bool cooling;
  final int? countdownSeconds;

  @override
  State<XbNodeCapsuleAction> createState() => _XbNodeCapsuleActionState();
}

class _XbNodeCapsuleActionState extends State<XbNodeCapsuleAction> {
  static const _corners = AppRadius.xl;
  static const _shape = RoundedRectangleBorder(borderRadius: _corners);
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = XbTokens.of(context);
    final enabled = widget.onTap != null;
    final focused = enabled && _focused;
    final color = widget.cooling || (!enabled && !widget.busy)
        ? tokens.onv
        : scheme.primary;
    const caption = AppTextStyle.caption2;
    final textStyle = TextStyle(
      fontSize: caption.size,
      fontWeight: caption.emphasizedWeight,
      height: 1,
      color: color,
    );
    final countdown = widget.countdownSeconds;
    final Widget? face;
    if (widget.busy) {
      face = null;
    } else if (countdown != null) {
      face = Text(
        '${countdown}s',
        maxLines: 1,
        style: textStyle.copyWith(
          fontSize: 10,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    } else {
      face = GlyphIcon(widget.glyph, size: widget.iconSize, color: color);
    }

    return Tooltip(
      message: widget.description,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: widget.description,
        button: true,
        enabled: enabled,
        focusable: enabled,
        focused: focused,
        onTap: widget.onTap,
        child: SizedBox(
          width: 76,
          height: 44,
          child: Material(
            key: widget.surfaceKey,
            type: MaterialType.transparency,
            borderRadius: _corners,
            clipBehavior: Clip.antiAlias,
            child: InkResponse(
              containedInkWell: true,
              highlightShape: BoxShape.rectangle,
              customBorder: _shape,
              excludeFromSemantics: true,
              onTap: widget.onTap,
              onFocusChange: (value) => setState(() => _focused = value),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: focused
                      ? Border.all(color: scheme.primary, width: 2)
                      : null,
                  borderRadius: _corners,
                ),
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (face != null) ...[face, const SizedBox(width: 4)],
                            Text(widget.label, maxLines: 1, style: textStyle),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
