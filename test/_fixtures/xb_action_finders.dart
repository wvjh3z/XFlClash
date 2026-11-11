import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Same action across a desktop text button and an Android icon tooltip.
Finder findActionLabel(Pattern pattern) => find.byWidgetPredicate((widget) {
  final label = switch (widget) {
    Text() => widget.data,
    Tooltip() => widget.message,
    _ => null,
  };
  if (label == null) return false;
  return pattern is String ? label == pattern : pattern.allMatches(label).isNotEmpty;
});
