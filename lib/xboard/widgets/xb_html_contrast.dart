/// Display-only color correction for supported flutter_html text/backgrounds.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_html/flutter_html.dart';

double xbHtmlContrastRatio(Color foreground, Color opaqueBackground) {
  final foregroundLuminance =
      Color.alphaBlend(foreground, opaqueBackground).computeLuminance();
  final backgroundLuminance = opaqueBackground.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance < backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Keep passing author colors exactly; otherwise change perceived lightness.
/// Quantize before checking so the rendered 8-bit color still clears 4.6.
Color xbReadableHtmlColor(Color foreground, Color opaqueBackground) {
  if (xbHtmlContrastRatio(foreground, opaqueBackground) >= 4.5) {
    return foreground;
  }
  final visible = Color.alphaBlend(foreground, opaqueBackground);
  final hsl = HSLColor.fromColor(visible);
  Color? best;
  var distance = double.infinity;
  for (var step = 0; step <= 1000; step++) {
    final lightness = step / 1000;
    final delta = (lightness - hsl.lightness).abs();
    if (delta >= distance) continue;
    final candidate = Color(hsl.withLightness(lightness).toColor().toARGB32());
    if (xbHtmlContrastRatio(candidate, opaqueBackground) >= 4.6) {
      best = candidate;
      distance = delta;
    }
  }
  return best ??
      (xbHtmlContrastRatio(const Color(0xFF000000), opaqueBackground) >= 4.5
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF));
}

/// Operates after flutter_html resolves CSS and inheritance, before spans build.
/// It does not intercept tag rendering, links, emoji fonts, or source HTML.
/// Only parsed solid backgrounds/RGBA colors are covered; unsupported browser
/// effects (background images/gradients, CSS opacity) remain parser limitations.
class XbHtmlContrastExtension extends HtmlExtension {
  const XbHtmlContrastExtension({
    required this.background,
    required this.foreground,
  });

  final Color background;
  final Color foreground;

  @override
  Set<String> get supportedTags => const {};

  @override
  bool matches(ExtensionContext context) =>
      context.currentStep == CurrentStep.preProcessing &&
      context.elementName == 'html';

  @override
  void beforeProcessing(ExtensionContext context) {
    final cache = <(Color, Color), Color>{};
    void visit(StyledElement node, Color parentBackground) {
      final paintedBackground = node.style.backgroundColor;
      final effectiveBackground = paintedBackground == null
          ? parentBackground
          : Color.alphaBlend(paintedBackground, parentBackground);
      // Flatten a translucent painted background to its actual solid result,
      // avoiding repeated alpha application by nested text/container painting.
      if (paintedBackground != null && paintedBackground.a > 0) {
        node.style.backgroundColor = effectiveBackground;
      }
      final color = node.style.color ?? foreground;
      node.style.color = cache.putIfAbsent(
        (color, effectiveBackground),
        () => xbReadableHtmlColor(color, effectiveBackground),
      );
      for (final child in node.children) {
        visit(child, effectiveBackground);
      }
    }

    visit(context.styledElement!, background);
  }
}
