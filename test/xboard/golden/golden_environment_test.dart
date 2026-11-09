import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'golden_environment.dart';

void main() {
  test('runtime guard accepts exactly the recorded toolchain', () {
    validateGoldenRuntime({...goldenRuntime});
    for (final key in goldenRuntime.keys) {
      expect(() => validateGoldenRuntime({...goldenRuntime, key: 'different'}), throwsStateError);
    }
  });
  test('font digest guard rejects missing or changed bytes', () {
    final bytes = [1, 2, 3];
    final digest = sha256.convert(bytes).toString();
    validateGoldenFont('fixture', bytes, digest);
    expect(() => validateGoldenFont('fixture', [], digest), throwsStateError);
    expect(() => validateGoldenFont('fixture', [1, 2, 4], digest), throwsStateError);
  });
  test('manifest requires all pinned font families and rejects substitutions', () {
    final entries = goldenFontAssets.entries.map((entry) => {
      'family': entry.key, 'fonts': [{'asset': entry.value}],
    }).toList();
    expect(validateGoldenFontManifest(jsonEncode(entries)), goldenFontAssets);
    expect(() => validateGoldenFontManifest(jsonEncode(entries.take(2).toList())), throwsStateError);
    expect(() => validateGoldenFontManifest(jsonEncode([...entries, entries.first])), throwsStateError);
    expect(() => validateGoldenFontManifest('{}'), throwsStateError);
    entries.first['fonts'] = [{'asset': 'missing-font.ttf'}];
    expect(() => validateGoldenFontManifest(jsonEncode(entries)), throwsStateError);
  });
  test('fallback normalization preserves explicit and inherited emoji families', () {
    const original = TextSpan(text: '正文', children: [
      TextSpan(text: '普通'),
      TextSpan(style: TextStyle(fontFamily: 'Twemoji'), children: [TextSpan(text: '🚀')]),
      TextSpan(text: '\ue88a', style: TextStyle(fontFamily: 'MaterialIcons')),
    ]);
    final result = goldenSpan(original) as TextSpan;
    expect(result.style!.fontFamily, 'Roboto');
    expect((result.children![0] as TextSpan).style!.fontFamily, 'Roboto');
    final emoji = result.children![1] as TextSpan;
    expect((emoji.children!.single as TextSpan).style!.fontFamily, 'Twemoji');
    expect((result.children![2] as TextSpan).style!.fontFamily, 'MaterialIcons');
    expect(result.toPlainText(), original.toPlainText());
    expect(original.style, isNull);
  });
}
