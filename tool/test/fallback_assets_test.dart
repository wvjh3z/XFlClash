import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import '../fallback_assets.dart';
import '../../test/xboard/services/_bootstrap_crypto_helper.dart';

void main() {
  final source = File('pubspec.yaml').readAsStringSync();
  test(
    'production input must authenticate and contain API and subscription endpoints',
    () async {
      final valid = await validEnvelope();
      await verifyFallbackInput(jsonEncode(valid.toJson()), testAesKey);
      await expectLater(
        verifyFallbackInput(jsonEncode(valid.toJson()), List.filled(32, 0)),
        throwsFormatException,
      );
      await expectLater(
        verifyFallbackInput('invalid json', testAesKey),
        throwsFormatException,
      );
      final empty = await validEnvelope(api: []);
      await expectLater(
        verifyFallbackInput(jsonEncode(empty.toJson()), testAesKey),
        throwsFormatException,
      );
    },
  );
  test(
    'actual pubspec A/B/A only selects the requested fallback, preserving other content',
    () {
      for (final newline in ['\n', '\r\n']) {
        var text = source.replaceAll('\r\n', '\n').replaceAll('\n', newline);
        final before = text.split(fallbackBegin).first;
        final after = text.split(fallbackEnd).last;
        for (final brand in ['brand_a', 'brand_b', 'brand_a']) {
          text = injectFallbackAsset(text, brand);
          expect(text, contains('- flavors/$brand/assets/fallback.bin'));
          expect(text.split(fallbackBegin).first, before);
          expect(text.split(fallbackEnd).last, after);
          expect(injectFallbackAsset(text, brand), text);
        }
      }
    },
  );
  test('missing or duplicate markers and additional brand entries fail', () {
    expect(
      () => injectFallbackAsset(source.replaceAll(fallbackEnd, ''), 'brand_a'),
      throwsFormatException,
    );
    expect(
      () => injectFallbackAsset(
        source + '\n$fallbackBegin\n$fallbackEnd',
        'brand_a',
      ),
      throwsFormatException,
    );
    expect(
      () => injectFallbackAsset(
        source.replaceFirst(
          fallbackEnd,
          '$fallbackEnd\n    - flavors/brand_b/assets/',
        ),
        'brand_a',
      ),
      throwsFormatException,
    );
    expect(
      () => injectFallbackAsset(source, '../other'),
      throwsFormatException,
    );
  });
}
