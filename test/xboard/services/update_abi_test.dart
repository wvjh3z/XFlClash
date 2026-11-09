import 'dart:ffi' show Abi;
import 'package:fl_clash/xboard/util/android_update_abi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in {
    Abi.androidArm: 'armeabi-v7a',
    Abi.androidArm64: 'arm64-v8a',
    Abi.androidX64: 'x86_64',
    Abi.androidIA32: 'x86',
  }.entries) {
    test('running Android ABI ${entry.key} requests ${entry.value}', () {
      expect(androidUpdateAbi(entry.key), entry.value);
    });
  }
  test('a non-Android ABI never silently selects an ARM64 APK', () {
    expect(() => androidUpdateAbi(Abi.linuxX64), throwsUnsupportedError);
    expect(() => androidUpdateAbi(Abi.windowsX64), throwsUnsupportedError);
  });
}
