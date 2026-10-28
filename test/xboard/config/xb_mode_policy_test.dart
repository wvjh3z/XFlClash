import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/config/xb_mode_policy.dart';

void bind(String brand, bool enabled) => XboardConfig.bind(
  XboardConfig(
    subscribeUserAgent: 'test',
    devApiEndpoint: 'https://api.example.invalid',
    devSubscriptionEndpoint: 'https://sub.example.invalid',
    debug: false,
    kIsTest: true,
    flavorId: brand,
    formA: enabled,
  ),
);

void main() {
  tearDown(XboardConfig.resetForTest);
  for (final brand in ['brand_a', 'brand_b']) {
    for (final enabled in [true, false]) {
      test(
        '$brand enabled=$enabled initial/update/restore normalize before notification',
        () {
          bind(brand, enabled);
          const original = PatchClashConfig(
            mode: Mode.direct,
            mixedPort: 9867,
            ipv6: true,
          );
          const saved = Config(
            themeProps: defaultThemeProps,
            patchClashConfig: original,
          );
          final c = ProviderContainer(overrides: buildConfigOverrides(saved));
          addTearDown(c.dispose);
          final seen = <Mode>[];
          c.listen(
            patchClashConfigProvider,
            (_, next) => seen.add(next.mode),
            fireImmediately: true,
          );
          expect(
            c.read(patchClashConfigProvider),
            enabled ? original.copyWith(mode: Mode.rule) : original,
          );
          c
              .read(patchClashConfigProvider.notifier)
              .update((s) => s.copyWith(mode: Mode.global));
          c.read(patchClashConfigProvider.notifier).value = original;
          c.read(commonActionProvider.notifier).updateMode();
          writeConfig(c.read(Provider((ref) => ref)), saved);
          expect(
            c.read(patchClashConfigProvider),
            enabled ? original.copyWith(mode: Mode.rule) : original,
          );
          expect(seen.contains(Mode.direct), !enabled);
          final persisted = c.read(configProvider).toJson();
          expect(
            Config.fromJson(
              jsonDecode(jsonEncode(persisted)) as Map<String, Object?>,
            ).patchClashConfig.mode,
            enabled ? Mode.rule : Mode.direct,
          );
          expect(
            xbAvailableModes,
            enabled ? [Mode.rule, Mode.global] : Mode.values,
          );
        },
      );
    }
  }
}
