import 'package:material_ui/material_ui.dart';

/// Only Nodes/Mine opt into the Android no-spinner presentation.
/// The refresh gesture, threshold, Future and other platforms stay native.
class XbTabRefreshIndicator extends StatelessWidget {
  const XbTabRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.android
      ? RefreshIndicator.noSpinner(onRefresh: onRefresh, child: child)
      : RefreshIndicator(onRefresh: onRefresh, child: child);
}
