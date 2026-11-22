import 'package:material_ui/material_ui.dart';

/// Keep legacy Material themes and localizations available to third-party
/// widgets (including flutter_html) inside a branded route or the Prism shell.
/// Remove when those consumers no longer use Flutter's bundled Material.
Widget xbLegacyMaterial(Widget child) =>
    // ignore: deprecated_member_use
    MaterialUiCompatibilityBridge(child: child);
