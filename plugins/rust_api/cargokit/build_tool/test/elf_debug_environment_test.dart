import 'package:build_tool/src/builder.dart';
import 'package:test/test.dart';

void main() {
  test('Native release/profile retain Rust debug information', () {
    for (final target in [
      'aarch64-linux-android',
      'armv7-linux-androideabi',
      'x86_64-linux-android',
      'aarch64-unknown-linux-gnu',
      'x86_64-unknown-linux-gnu',
      'x86_64-apple-darwin',
      'aarch64-apple-darwin',
      'x86_64-pc-windows-msvc',
      'aarch64-pc-windows-msvc',
    ]) {
      expect(nativeDebugEnvironment(target), {
        'CARGO_PROFILE_RELEASE_DEBUG': '2',
        'CARGO_PROFILE_RELEASE_STRIP': 'none',
      });
    }
  });

  test('Other targets retain their existing Cargo profile', () {
    for (final target in [
      'aarch64-apple-ios',
    ]) {
      expect(nativeDebugEnvironment(target), isEmpty);
    }
  });
}
