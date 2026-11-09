import 'dart:ffi' show Abi;

/// Identify the running binary, not the device's preferred ABI or a shared
/// build define: split-per-abi builds reuse the same Dart defines for both APKs.
String androidUpdateAbi(Abi abi) => switch (abi) {
  Abi.androidArm => 'armeabi-v7a',
  Abi.androidArm64 => 'arm64-v8a',
  Abi.androidX64 => 'x86_64',
  Abi.androidIA32 => 'x86',
  _ => throw UnsupportedError('Not an Android runtime ABI: $abi'),
};
