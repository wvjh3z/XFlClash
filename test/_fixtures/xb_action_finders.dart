import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Same action across a desktop text button and an Android capsule tooltip.
Finder findActionLabel(Pattern pattern) {
  bool matches(String? label) =>
      label != null &&
      (pattern is String ? label == pattern : pattern.allMatches(label).isNotEmpty);

  return find.byElementPredicate((element) {
    final widget = element.widget;
    if (widget is Tooltip) return matches(widget.message);
    if (widget is! Text || !matches(widget.data)) return false;
    var insideMatchingTooltip = false;
    element.visitAncestorElements((ancestor) {
      final tooltip = ancestor.widget;
      insideMatchingTooltip = tooltip is Tooltip && matches(tooltip.message);
      return !insideMatchingTooltip;
    });
    return !insideMatchingTooltip;
  });
}
