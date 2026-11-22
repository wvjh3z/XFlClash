import 'package:material_ui/material_ui.dart';

/// A new object is issued for each explicit Home/Nodes request, even for the
/// same plan. A direct tab selection never issues one.
class XbShopIntent {
  const XbShopIntent({
    required this.revision,
    required this.authenticated,
    required this.planId,
    required this.waitForProfile,
  });

  final int revision;
  final bool authenticated;
  final int? planId;
  final bool waitForProfile;
}

/// Lets a brand-page action request its owning shell's tab, not a new route.
class XbShopNavigation extends InheritedWidget {
  const XbShopNavigation({
    super.key,
    required this.onOpen,
    required super.child,
  });

  final ValueChanged<XbShopIntent> onOpen;

  static XbShopNavigation? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<XbShopNavigation>();

  @override
  bool updateShouldNotify(XbShopNavigation oldWidget) => false;
}
