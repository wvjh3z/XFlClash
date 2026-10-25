import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../android_brand_identity.dart';
import '../identity/brands.dart';
import '../prepare_flavor.dart';

void main() {
  test('clean single-brand CI rejects colliding custom IDs independently', () {
    for (final brand in ['brand_a', 'brand_b']) {
      final root = Directory.systemTemp.createTempSync('isolated-brand-');
      try {
        expect(
          () => generateAndroidBrandIdentities(
            root: root,
            selectedFlavor: brand,
            selectedSource: utf8.encode(
              '{appName: Test, appId: com.example.shared}',
            ),
          ),
          throwsFormatException,
        );
        final identity = jsonDecode(
          generateAndroidBrandIdentities(
            root: root,
            selectedFlavor: brand,
            selectedSource: utf8.encode(
              '{appName: Test, appId: ${brandIdentities[brand]!['id']}}',
            ),
          ),
        );
        expect((identity['brands'] as Map).keys.toList(), [brand]);
      } finally {
        root.deleteSync(recursive: true);
      }
    }
  });

  test('reject upstream and the other brand package identities', () {
    for (final brand in ['brand_a', 'brand_b']) {
      final other = brand == 'brand_a' ? 'daishu' : 'omofly';
      for (final id in [
        'com.follow.clash',
        'com.follow.clash.dev',
        'com.cloud.app.$other',
        'com.cloud.app.$other.dev',
      ]) {
        expect(
          () => androidBrandIdentity(
            utf8.encode('appName: Test\nappId: $id\n'),
            brand,
          ),
          throwsFormatException,
        );
      }
    }
  });
  test('reject duplicate IDs even for custom brand configurations', () {
    final root = Directory.systemTemp.createTempSync('brand-duplicates-');
    addTearDown(() => root.deleteSync(recursive: true));
    final b = File('${root.path}/flavors/brand_b/flavor.yaml');
    b.parent.createSync(recursive: true);
    b.writeAsStringSync('appName: B\nappId: com.example.same\n');
    expect(
      () => generateAndroidBrandIdentities(
        root: root,
        selectedFlavor: 'brand_a',
        selectedSource: utf8.encode('appName: A\nappId: com.example.same\n'),
      ),
      throwsFormatException,
    );
  });

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
                "appName: ${entry.value}\nappId: '${brandIdentities[brand]!['id']}'\naesKey: private-fixture-marker\n"
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
            expect(identity['appId'], '${brandIdentities[brand]!['id']}');
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
      b.writeAsStringSync('appName: 袋鼠加速\nappId: com.cloud.app.daishu\n');
      final a = utf8.encode('appName: OmoFly\nappId: com.cloud.app.omofly\n');
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
