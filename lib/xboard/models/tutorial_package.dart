/// Official article slots are identifiers, never package URLs from the article.
enum TutorialPackage {
  windowsX64('windows-amd64-exe', 'windows', 'x64', 'exe', 'Windows · Intel / AMD（x64）'),
  windowsArm('windows-arm64-exe', 'windows', 'arm64', 'exe', 'Windows · ARM64'),
  macIntel('macos-amd64-dmg', 'macos', 'x64', 'dmg', 'macOS · Intel'),
  macApple('macos-arm64-dmg', 'macos', 'arm64', 'dmg', 'macOS · Apple 芯片'),
  android64('android-arm64-v8a-apk', 'android', 'arm64-v8a', 'apk', 'Android · ARM64'),
  android32('android-armeabi-v7a-apk', 'android', 'armeabi-v7a', 'apk', 'Android · ARMv7'),
  linuxX64('linux-amd64-appimage', 'linux', 'x64', 'appimage', 'Linux · x64 · AppImage'),
  linuxArm('linux-arm64-appimage', 'linux', 'arm64', 'appimage', 'Linux · ARM64 · AppImage'),
  debX64('linux-amd64-deb', 'linux', 'x64', 'deb', 'Linux · x64 · DEB'),
  debArm('linux-arm64-deb', 'linux', 'arm64', 'deb', 'Linux · ARM64 · DEB'),
  rpm('linux-amd64-rpm', 'linux', 'x64', 'rpm', 'Linux · x64 · RPM');

  const TutorialPackage(this.slot, this.platform, this.abi, this.extension, this.label);
  final String slot, platform, abi, extension, label;
  String? get format => extension == 'deb' || extension == 'rpm' ? extension : null;
  static const linkPrefix = 'https://tutorial-download.invalid/';
  static TutorialPackage? match(String? platform, String? slot, String? apk) {
    final id = slot ?? (platform == 'android' ? 'android-$apk-apk' : null);
    return values.where((p) => p.platform == platform && p.slot == id).firstOrNull;
  }
  bool accepts(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.isScheme('https') || uri.isScheme('http')) &&
        uri.host.isNotEmpty && uri.userInfo.isEmpty && uri.path.toLowerCase().endsWith('.$extension');
  }
}
