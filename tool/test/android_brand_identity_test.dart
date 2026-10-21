import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../android_brand_identity.dart';
import '../prepare_flavor.dart';

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    final name = brand == 'brand_a' ? 'OmoFly' : '袋鼠加速';
    for (final entry in {
      'plain': name,
      'double': jsonEncode(name),
      'single': "'$name'",
      'unicode': brand == 'brand_a'
          ? r'"\u004FmoFly"'
          : r'"\u888B\u9F20\u52A0\u901F"',
      'apostrophe': "'袋鼠''s # 客户端'",
      'supplementary': r'"袋鼠 \U0001F998"',
    }.entries) {
      for (final newline in ['\n', '\r\n']) {
        test(
          '$brand ${entry.key} newline=${newline.length} matches Dart configuration',
          () {
            final source =
                "appName: ${entry.value}\nappId: 'com.example.$brand'\naesKey: private-fixture-marker\n"
                    .replaceAll('\n', newline);
            final bytes = utf8.encode(source);
            final identity = androidBrandIdentity(bytes, brand);
            final defines = jsonDecode(
              generateFlavorDefinesJson(
                loadYaml(source) as YamlMap,
                flavorId: brand,
                isTest: true,
              ),
            );
            expect(identity['appName'], defines['XB_APP_NAME']);
            expect(identity['appId'], 'com.example.$brand');
            expect(identity['sourceSha256'], sha256.convert(bytes).toString());
            expect(identity.keys.toSet(), {'appName', 'appId', 'sourceSha256'});
            expect(
              jsonEncode(identity),
              isNot(contains('private-fixture-marker')),
            );
          },
        );
      }
    }
  }
  test('invalid identity fails without echoing private input', () {
    for (final source in [
      'appName: 123\nappId: com.example.app',
      'appName: ""\nappId: com.example.app',
      'appName: "bad\\nname"\nappId: com.example.app',
      'appName: safe\nappId: bad id',
      'appName: [private-fixture-marker',
    ]) {
      expect(
        () => androidBrandIdentity(utf8.encode(source), 'brand_a'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'safe diagnostic',
            isNot(contains('private-fixture-marker')),
          ),
        ),
      );
    }
  });
  test(
    'prepare includes present brands and drops removed brands on regeneration',
    () {
      final root = Directory.systemTemp.createTempSync('brand-identity-');
      addTearDown(() => root.deleteSync(recursive: true));
      final b = File('${root.path}/flavors/brand_b/flavor.yaml');
      b.parent.createSync(recursive: true);
      b.writeAsStringSync('appName: 袋鼠加速\nappId: com.example.b\n');
      final a = utf8.encode('appName: OmoFly\nappId: com.example.a\n');
      Map<String, dynamic> generate() => jsonDecode(
        generateAndroidBrandIdentities(
          root: root,
          selectedFlavor: 'brand_a',
          selectedSource: a,
        ),
      );
      expect((generate()['brands'] as Map).keys.toSet(), {
        'brand_a',
        'brand_b',
      });
      b.deleteSync();
      expect((generate()['brands'] as Map).keys.toList(), ['brand_a']);
      expect(generate()['schemaVersion'], 1);
    },
  );
}
