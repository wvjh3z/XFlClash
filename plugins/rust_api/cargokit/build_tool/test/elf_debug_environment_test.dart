import 'package:build_tool/src/builder.dart';
import 'package:test/test.dart';

void main() {
  test('Android and Linux release/profile keep Rust DWARF', () {
    for (final target in [
      'aarch64-linux-android',
      'armv7-linux-androideabi',
      'x86_64-linux-android',
      'aarch64-unknown-linux-gnu',
      'x86_64-unknown-linux-gnu',
    ]) {
      expect(elfDebugEnvironment(target), {
        'CARGO_PROFILE_RELEASE_DEBUG': '2',
        'CARGO_PROFILE_RELEASE_STRIP': 'none',
      });
    }
  });

  test('Windows and macOS keep their existing Cargo profile', () {
    for (final target in [
      'x86_64-pc-windows-msvc',
      'aarch64-pc-windows-msvc',
      'x86_64-apple-darwin',
      'aarch64-apple-darwin',
    ]) {
      expect(elfDebugEnvironment(target), isEmpty);
    }
  });
}
