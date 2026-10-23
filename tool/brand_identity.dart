// Stable public identities. Display names and private panel config are separate.
import 'dart:convert';
import 'identity/brands.dart';

Map<String, dynamic> brandIdentity(String flavor, {String? root}) {
  final value = brandIdentities[flavor];
  if (value == null) throw const FormatException('Unknown brand identity');
  final result = Map<String, dynamic>.from(value);
  for (final key in [
    'id',
    'slug',
    'name',
    'windowsService',
    'linuxService',
    'runtimeDirectory',
    'scheme',
  ]) {
    if (result[key] is! String ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9.-]*$').hasMatch(result[key] as String)) {
      throw const FormatException('Invalid stable brand identity');
    }
  }
  if (result['mixedPort'] is! int ||
      result['mixedPort'] < 1024 ||
      result['mixedPort'] > 65535 ||
      !RegExp(
        r'^[A-F0-9-]{36}$',
      ).hasMatch(result['installerId'] as String? ?? '')) {
    throw const FormatException('Invalid installer identity');
  }
  return result;
}

Map<String, String> brandDefines(Map<String, dynamic> identity) => {
  'XB_NATIVE_ID': identity['id'] as String,
  'XB_NATIVE_NAME': identity['name'] as String,
  'XB_BRAND_SLUG': identity['slug'] as String,
  'XB_HELPER_WINDOWS_SERVICE': identity['windowsService'] as String,
  'XB_HELPER_SOCKET': '/run/${identity['runtimeDirectory']}/helper.sock',
  'XB_URL_SCHEME': identity['scheme'] as String,
  'XB_DEFAULT_MIXED_PORT': '${identity['mixedPort']}',
  'XB_WINDOWS_CORE_NAME': '${identity['name']}Core',
  'XB_WINDOWS_HELPER_NAME': '${identity['name']}HelperService',
};

String replaceIdentity(String source, RegExp pattern, String replacement) {
  if (pattern.allMatches(source).length != 1) {
    throw const FormatException(
      'Identity injection target missing or ambiguous',
    );
  }
  return source.replaceFirstMapped(pattern, (_) => replacement);
}

String injectStableIdentity(
  String source,
  String path,
  Map<String, dynamic> id, {
  String platform = 'windows',
}) {
  var s = source;
  String set(String key, String value) {
    final pattern = RegExp('^$key:[^\\r\\n]*', multiLine: true);
    if (pattern.allMatches(s).length > 1) {
      throw const FormatException('Duplicate identity field');
    }
    return pattern.hasMatch(s)
        ? s.replaceFirstMapped(pattern, (_) => '$key: ${jsonEncode(value)}')
        : '${s.trimRight()}\n$key: ${jsonEncode(value)}\n';
  }

  switch (path) {
    case 'build_config.yaml':
      s = set(
        'core_name',
        platform == 'windows' ? '${id['name']}Core' : 'FlClashCore',
      );
      s = set(
        'helper_name',
        platform == 'windows'
            ? '${id['name']}HelperService'
            : 'FlClashHelperService',
      );
    case 'windows/CMakeLists.txt':
      s = replaceIdentity(
        s,
        RegExp(r'set\(BINARY_NAME "[^"]+"\)'),
        'set(BINARY_NAME "${id['name']}")',
      );
      s = s.replaceAll(
        RegExp(r'(?:FlClash|OmoFly|Daishu)Core'),
        '${id['name']}Core',
      );
      s = s.replaceAll(
        RegExp(r'(?:FlClash|OmoFly|Daishu)HelperService'),
        '${id['name']}HelperService',
      );
    case 'windows/packaging/exe/inno_setup.iss':
      s = replaceIdentity(
        s,
        RegExp(r'#define XbServiceName "[^"]+"'),
        '#define XbServiceName "${id['windowsService']}"',
      );
      s = replaceIdentity(
        s,
        RegExp(r"Schemes := \['[^']+'\];"),
        "Schemes := ['${id['scheme']}'];",
      );
    case 'windows/runner/Runner.rc':
      for (final pair in [
        ('CompanyName', 'com.cloud.app'),
        ('ProductName', id['slug'] as String),
      ]) {
        s = replaceIdentity(
          s,
          RegExp('VALUE "${pair.$1}", "[^"]*"'),
          'VALUE "${pair.$1}", "${pair.$2}"',
        );
      }
    case 'windows/packaging/exe/make_config.yaml':
      s = set('app_id', id['installerId'] as String);
      s = set('app_name', id['name'] as String);
      s = set('executable_name', '${id['name']}.exe');
      s = set('install_dir_name', '{autopf}\\${id['name']} Client');
    case 'macos/Runner/Configs/AppInfo.xcconfig':
      s = replaceIdentity(
        s,
        RegExp(r'^PRODUCT_BUNDLE_IDENTIFIER = .*$', multiLine: true),
        'PRODUCT_BUNDLE_IDENTIFIER = ${id['id']}',
      );
    case 'macos/Runner.xcodeproj/project.pbxproj':
      s = replaceIdentity(
        s,
        RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9.]+\.debug;'),
        'PRODUCT_BUNDLE_IDENTIFIER = ${id['id']}.debug;',
      );
    case 'macos/Runner/Info.plist':
      s = replaceIdentity(
        s,
        RegExp(r'(<key>CFBundleURLSchemes</key>\s*)<array>[\s\S]*?</array>'),
        '<key>CFBundleURLSchemes</key>\n<array><string>${id['scheme']}</string></array>',
      );
    case 'linux/CMakeLists.txt':
      s = replaceIdentity(
        s,
        RegExp(r'set\(APPLICATION_ID "[^"]+"\)'),
        'set(APPLICATION_ID "${id['id']}")',
      );
    case 'linux/packaging/deb/make_config.yaml':
    case 'linux/packaging/rpm/make_config.yaml':
    case 'linux/packaging/appimage/make_config.yaml':
      if (path.contains('/deb/')) s = set('package_name', id['slug'] as String);
      s = set('startup_wm_class', id['id'] as String);
      s = s.replaceAllMapped(
        RegExp(r'x-scheme-handler/[a-z][a-z0-9.+-]*'),
        (_) => 'x-scheme-handler/${id['scheme']}',
      );
      // Deduplicate repeated legacy scheme lines after replacing all of them.
      s = s.replaceAll(
        RegExp('(  - x-scheme-handler/${id['scheme']}\r?\n){2,}'),
        '  - x-scheme-handler/${id['scheme']}\n',
      );
      s = s.replaceAll(
        RegExp(r'(?:flclash|omofly|daishu)-helper'),
        id['linuxService'] as String,
      );
      if (path.contains('/deb/')) {
        s = s.replaceAll(
          RegExp(r'/usr/share/(?:FlClash|omofly|daishu)/FlClashHelperService'),
          '/usr/share/${id['slug']}/FlClashHelperService',
        );
      }
    case 'services/helper/src/service/windows.rs':
      s = replaceIdentity(
        s,
        RegExp(r'const SERVICE_NAME: &str = "[^"]+";'),
        'const SERVICE_NAME: &str = "${id['windowsService']}";',
      );
    case 'services/helper/src/service/peer.rs':
      s = replaceIdentity(
        s,
        RegExp(r'const PORT_KEY: &str = r"[^"]+";'),
        'const PORT_KEY: &str = r"SYSTEM\\CurrentControlSet\\Services\\${id['windowsService']}\\Runtime";',
      );
    case 'services/helper/src/service/linux.rs':
      for (final pair in [
        ('SERVICE_NAME', id['linuxService']),
        ('UNIT_PATH', '/etc/systemd/system/${id['linuxService']}.service'),
        ('RUNTIME_DIR_NAME', id['runtimeDirectory']),
        ('SOCKET_PATH', '/run/${id['runtimeDirectory']}/helper.sock'),
      ]) {
        s = replaceIdentity(
          s,
          RegExp('const ${pair.$1}: &str = "[^"]+";'),
          'const ${pair.$1}: &str = "${pair.$2}";',
        );
      }
      s = s.replaceAll(
        RegExp(r'RuntimeDirectory=(?:flclash|omofly|daishu)\\n'),
        'RuntimeDirectory=${id['runtimeDirectory']}\\n',
      );
  }
  return s;
}
