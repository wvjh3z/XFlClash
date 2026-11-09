import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/prism_ui.dart' as prism;

material.ColorScheme xbMaterialColorScheme(prism.ColorScheme source) =>
    material.ColorScheme(
      brightness: source.brightness,
      primary: source.primary,
      onPrimary: source.onPrimary,
      primaryContainer: source.primaryContainer,
      onPrimaryContainer: source.onPrimaryContainer,
      primaryFixed: source.primaryFixed,
      primaryFixedDim: source.primaryFixedDim,
      onPrimaryFixed: source.onPrimaryFixed,
      onPrimaryFixedVariant: source.onPrimaryFixedVariant,
      secondary: source.secondary,
      onSecondary: source.onSecondary,
      secondaryContainer: source.secondaryContainer,
      onSecondaryContainer: source.onSecondaryContainer,
      secondaryFixed: source.secondaryFixed,
      secondaryFixedDim: source.secondaryFixedDim,
      onSecondaryFixed: source.onSecondaryFixed,
      onSecondaryFixedVariant: source.onSecondaryFixedVariant,
      tertiary: source.tertiary,
      onTertiary: source.onTertiary,
      tertiaryContainer: source.tertiaryContainer,
      onTertiaryContainer: source.onTertiaryContainer,
      tertiaryFixed: source.tertiaryFixed,
      tertiaryFixedDim: source.tertiaryFixedDim,
      onTertiaryFixed: source.onTertiaryFixed,
      onTertiaryFixedVariant: source.onTertiaryFixedVariant,
      error: source.error,
      onError: source.onError,
      errorContainer: source.errorContainer,
      onErrorContainer: source.onErrorContainer,
      surface: source.surface,
      onSurface: source.onSurface,
      surfaceDim: source.surfaceDim,
      surfaceBright: source.surfaceBright,
      surfaceContainerLowest: source.surfaceContainerLowest,
      surfaceContainerLow: source.surfaceContainerLow,
      surfaceContainer: source.surfaceContainer,
      surfaceContainerHigh: source.surfaceContainerHigh,
      surfaceContainerHighest: source.surfaceContainerHighest,
      onSurfaceVariant: source.onSurfaceVariant,
      outline: source.outline,
      outlineVariant: source.outlineVariant,
      shadow: source.shadow,
      scrim: source.scrim,
      inverseSurface: source.inverseSurface,
      onInverseSurface: source.onInverseSurface,
      inversePrimary: source.inversePrimary,
      surfaceTint: source.surfaceTint,
    );

material.ThemeData xbMaterialHostTheme(prism.ThemeData source) =>
    material.ThemeData(
      useMaterial3: true,
      colorScheme: xbMaterialColorScheme(source.colorScheme),
      platform: source.platform,
      fontFamily: source.fontFamily,
      fontFamilyFallback: source.fontFamilyFallback,
      scaffoldBackgroundColor: source.scaffoldBackgroundColor,
      visualDensity: material.VisualDensity(
        horizontal: source.visualDensity.horizontal,
        vertical: source.visualDensity.vertical,
      ),
      materialTapTargetSize: switch (source.tapTargetSize) {
        prism.TapTargetSize.padded => material.MaterialTapTargetSize.padded,
        prism.TapTargetSize.shrinkWrap => material.MaterialTapTargetSize.shrinkWrap,
      },
    );

/// Above the Navigator so pushed brand routes share the same Material host.
class XbUiCompatibilityHost extends StatelessWidget {
  const XbUiCompatibilityHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => material.Theme(
    data: xbMaterialHostTheme(prism.Theme.of(context)),
    child: material.ScaffoldMessenger(
      child: material.MaterialUiCompatibilityBridge(child: child),
    ),
  );
}
