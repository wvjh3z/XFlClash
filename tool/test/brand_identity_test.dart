import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';
import '../brand_identity.dart';

void main() {
  final paths = [
    'build_config.yaml',
    'windows/CMakeLists.txt',
    'windows/runner/Runner.rc',
    'windows/packaging/exe/inno_setup.iss',
    'windows/packaging/exe/make_config.yaml',
    'linux/CMakeLists.txt',
    'linux/packaging/deb/make_config.yaml',
    'linux/packaging/rpm/make_config.yaml',
    'linux/packaging/appimage/make_config.yaml',
    'macos/Runner/Configs/AppInfo.xcconfig',
    'macos/Runner/Info.plist',
    'macos/Runner.xcodeproj/project.pbxproj',
    'services/helper/src/service/windows.rs',
    'services/helper/src/service/linux.rs',
    'services/helper/src/service/peer.rs',
  ];
  test('stable public identities are pairwise distinct', () {
    final a = brandIdentity('brand_a'), b = brandIdentity('brand_b');
    for (final key in a.keys) {
      expect(a[key], isNot(b[key]), reason: key);
    }
    expect(() => brandIdentity('unknown'), throwsFormatException);
    expect(brandDefines(a)['XB_WINDOWS_CORE_NAME'], 'OmoFlyCore');
  });
  for (final path in paths) {
    test('$path A B A repeated injection leaves no stale identity', () {
      final source = File(path).readAsStringSync();
      final a = brandIdentity('brand_a'), b = brandIdentity('brand_b');
      final first = injectStableIdentity(source, path, a);
      expect(injectStableIdentity(first, path, a), first);
      final second = injectStableIdentity(first, path, b);
      expect(injectStableIdentity(second, path, a), first);
      if (path.endsWith('.yaml')) expect(loadYaml(second), isA<Map>());
      if (path == 'windows/CMakeLists.txt') {
        expect(second, contains('set(BINARY_NAME "Daishu")'));
        expect(second, isNot(contains('/FlClashCore.exe')));
      }
      if (path.endsWith('service/windows.rs'))
        expect(second, contains('"DaishuHelperService"'));
      if (path.endsWith('service/peer.rs'))
        expect(second, contains(r'Services\DaishuHelperService\Runtime'));
    });
  }
  test('Windows native names reset when switching to Linux', () {
    final source = File('build_config.yaml').readAsStringSync();
    final a = brandIdentity('brand_a');
    final win = injectStableIdentity(source, 'build_config.yaml', a);
    final linux = loadYaml(
      injectStableIdentity(win, 'build_config.yaml', a, platform: 'linux'),
    );
    expect(linux['core_name'], 'FlClashCore');
    expect(linux['helper_name'], 'FlClashHelperService');
  });
  test('missing critical native constants are rejected', () {
    expect(
      () => injectStableIdentity(
        '',
        'services/helper/src/service/windows.rs',
        brandIdentity('brand_a'),
      ),
      throwsFormatException,
    );
  });
}
