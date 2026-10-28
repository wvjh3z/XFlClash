import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';

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
      testWidgets(
        '$brand enabled=$enabled actual hotkey event cycle and legacy direct',
        (tester) async {
          bind(brand, enabled);
          final bindings = [
            HotKeyAction(
              action: HotAction.mode,
              key: PhysicalKeyboardKey.keyM.usbHidUsage,
              modifiers: const {KeyboardModifier.control, KeyboardModifier.alt},
            ),
            HotKeyAction(
              action: HotAction.directMode,
              key: PhysicalKeyboardKey.keyD.usbHidUsage,
              modifiers: const {KeyboardModifier.control, KeyboardModifier.alt},
            ),
          ];
          final registered = <int>[];
          final c = ProviderContainer(
            overrides: [
              currentProfileProvider.overrideWith((_) => null),
              hotKeyActionsProvider.overrideWithValue(bindings),
            ],
          );
          final events = StreamController<int>.broadcast();
          addTearDown(() async {
            await events.close();
            c.dispose();
          });
          final observed = <Mode>[];
          c.listen(
            patchClashConfigProvider,
            (_, next) => observed.add(next.mode),
          );
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: HotKeyManager(
                registerHotKeys: ({required specs}) async {
                  registered
                    ..clear()
                    ..addAll(specs.map((s) => s.id));
                  return [];
                },
                hotKeyEventSource: () => events.stream,
                child: const SizedBox(),
              ),
            ),
          );
          await tester.pump();
          expect(
            registered,
            containsAll([HotAction.mode.index, HotAction.directMode.index]),
          );
          expect(c.read(hotKeyActionsProvider), bindings);
          events.add(HotAction.mode.index);
          await tester.pump();
          expect(c.read(patchClashConfigProvider).mode, Mode.global);
          events.add(HotAction.mode.index);
          await tester.pump();
          expect(
            c.read(patchClashConfigProvider).mode,
            enabled ? Mode.rule : Mode.direct,
          );
          events.add(HotAction.directMode.index);
          await tester.pump();
          expect(
            c.read(patchClashConfigProvider).mode,
            enabled ? Mode.rule : Mode.direct,
          );
          if (enabled) {
            expect(observed, isNot(contains(Mode.direct)));
          }
        },
      );
    }
  }
}
