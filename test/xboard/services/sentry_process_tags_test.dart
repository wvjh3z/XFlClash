import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/sentry_process_tags.dart';

void main() {
  test('release targets retain process architecture and bounded platform tags', () {
    final targets = {
      Abi.windowsX64: ('windows', 'amd64'),
      Abi.windowsArm64: ('windows', 'arm64'),
      Abi.linuxX64: ('linux', 'amd64'),
      Abi.linuxArm64: ('linux', 'arm64'),
      Abi.macosX64: ('macos', 'amd64'),
      Abi.macosArm64: ('macos', 'arm64'),
      Abi.androidArm: ('android', 'arm'),
      Abi.androidArm64: ('android', 'arm64'),
    };
    for (final entry in targets.entries) {
      expect(sentryProcessTags(entry.key), {
        'xb.platform': entry.value.$1,
        'xb.arch': entry.value.$2,
      });
    }
  });

  test('unsupported target is not guessed as amd64', () {
    expect(sentryProcessTags(Abi.iosArm64), {
      'xb.platform': 'unknown',
      'xb.arch': 'unknown',
    });
  });
}
