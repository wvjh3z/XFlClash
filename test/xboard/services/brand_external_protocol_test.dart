import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import '../../../tool/brand_identity.dart';

void main() {
  test('desktop identity injection removes external schemes across A/B/A', () {
    var plist = File('macos/Runner/Info.plist').readAsStringSync();
    final configs = {
      for (final kind in ['deb', 'rpm', 'appimage'])
        'linux/packaging/$kind/make_config.yaml':
            File('linux/packaging/$kind/make_config.yaml').readAsStringSync(),
    };
    for (final brand in ['brand_a', 'brand_b', 'brand_a']) {
      final id = brandIdentity(brand);
      plist = injectStableIdentity(plist, 'macos/Runner/Info.plist', id);
      expect(plist, isNot(contains('CFBundleURLTypes')));
      expect(plist, isNot(contains('CFBundleURLSchemes')));
      expect(plist, contains('CFBundleExecutable'));
      for (final path in configs.keys) {
        configs[path] = injectStableIdentity(configs[path]!, path, id, platform: 'linux');
        expect(configs[path], isNot(contains('x-scheme-handler/')));
        final yaml = loadYaml(configs[path]!) as YamlMap;
        expect(yaml['supported_mime_type'], isEmpty);
        expect(yaml['startup_wm_class'], id['id']);
      }
    }
  });
}
