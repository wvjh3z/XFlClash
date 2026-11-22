import 'dart:ffi' show Abi;

/// Running process ABI, not host CPU: an x64 build under emulation stays amd64.
/// Only bounded diagnostic labels; no device identifier or additional event.
Map<String, String> sentryProcessTags(Abi abi) {
  final (platform, arch) = switch (abi) {
    Abi.windowsX64 => ('windows', 'amd64'),
    Abi.windowsArm64 => ('windows', 'arm64'),
    Abi.windowsIA32 => ('windows', 'x86'),
    Abi.linuxX64 => ('linux', 'amd64'),
    Abi.linuxArm64 => ('linux', 'arm64'),
    Abi.linuxIA32 => ('linux', 'x86'),
    Abi.linuxArm => ('linux', 'arm'),
    Abi.macosX64 => ('macos', 'amd64'),
    Abi.macosArm64 => ('macos', 'arm64'),
    Abi.androidX64 => ('android', 'amd64'),
    Abi.androidArm64 => ('android', 'arm64'),
    Abi.androidIA32 => ('android', 'x86'),
    Abi.androidArm => ('android', 'arm'),
    _ => ('unknown', 'unknown'),
  };
  return {'xb.platform': platform, 'xb.arch': arch};
}

Map<String, String> currentSentryProcessTags() => sentryProcessTags(Abi.current());
