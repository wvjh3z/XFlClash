import 'dart:io';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

XboardConfig config(String yaml, {bool formA = true}) => XboardConfig(
  subscribeUserAgent: 'test/flclash',
  devApiEndpoint: '',
  devSubscriptionEndpoint: '',
  debug: true,
  kIsTest: true,
  formA: formA,
  appName: (loadYaml(yaml) as YamlMap)['appName'] as String,
);

// Keep the lifecycle-heavy Application out of this platform-channel test;
// verify its actual named argument separately, accepting whitespace and CRLF.
final _titleBinding = RegExp(
  r'^\s*title\s*:\s*XboardConfig\s*\.\s*current\s*\.\s*applicationTitle\s*\(\s*fallback\s*:\s*appName\s*,?\s*\)\s*,',
  multiLine: true,
);

void main() {
  test('real Application uses the tested policy; old binding is rejected', () {
    final source = File('lib/application.dart').readAsStringSync();
    for (final text in [source, source.replaceAll('\n', '\r\n')]) {
      expect(_titleBinding.allMatches(text).length, 1);
      expect(
        _titleBinding.hasMatch(
          text.replaceAll(_titleBinding, '\n title: appName,'),
        ),
        isFalse,
      );
    }
    expect(
      _titleBinding.hasMatch(
        '  title: XboardConfig.current\n .applicationTitle(\n fallback: appName,\n ),',
      ),
      isTrue,
    );
  });
  testWidgets(
    'both brands, YAML escapes and switches reach the recent-task channel',
    (tester) async {
      final labels = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setApplicationSwitcherDescription') {
            labels.add(call.arguments['label'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      for (final row in [
        ['appName: OmoFly', 'OmoFly'],
        ["appName: '袋鼠加速'", '袋鼠加速'],
        [r'appName: "\u888B\u9F20\u52A0\u901F"', '袋鼠加速'],
        ["appName: 'OmoFly'", 'OmoFly'],
        [r'appName: "袋鼠 \U0001F998"', '袋鼠 🦘'],
      ]) {
        final title = config(row[0]).applicationTitle(fallback: 'FlClash');
        await tester.pumpWidget(
          MaterialApp(title: title, home: const SizedBox()),
        );
        expect(labels.last, row[1]);
        final count = labels.length;
        await tester.pumpWidget(
          MaterialApp(title: title, home: const SizedBox()),
        );
        expect(labels.length, count, reason: 'same title must not re-send');
      }
      await tester.pumpWidget(
        MaterialApp(
          title: config(
            'appName: 袋鼠加速',
            formA: false,
          ).applicationTitle(fallback: 'FlClash'),
          home: const SizedBox(),
        ),
      );
      expect(labels.last, 'FlClash');
    },
  );
}
