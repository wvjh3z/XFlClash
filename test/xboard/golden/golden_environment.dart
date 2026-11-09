/// Shared Linux golden environment. Test-only; never changes production themes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _environment = jsonDecode(File('test/xboard/golden/environment.json').readAsStringSync()) as Map<String, dynamic>;
final goldenRuntime = Map<String, String>.from(_environment['runtime'] as Map);
final goldenCjkPath = (_environment['cjk'] as Map)['defaultPath'] as String;
final goldenCjkSha256 = (_environment['cjk'] as Map)['sha256'] as String;
final goldenFontAssets = Map<String, String>.from(_environment['fontAssets'] as Map);
final goldenAssetSha256 = Map<String, String>.from(_environment['assetSha256'] as Map);

void validateGoldenRuntime(Map<String, dynamic> actual) {
  for (final entry in goldenRuntime.entries) {
    if (actual[entry.key] != entry.value) {
      throw StateError('Golden ${entry.key}: expected ${entry.value}, got ${actual[entry.key]}');
    }
  }
}

void validateGoldenFont(String name, List<int> bytes, String expectedSha256) {
  if (sha256.convert(bytes).toString() != expectedSha256) {
    throw StateError('Golden font digest mismatch: $name');
  }
}

Map<String, String> validateGoldenFontManifest(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) throw StateError('Golden FontManifest must be a list');
  final found = <String, String>{};
  for (final entry in decoded) {
    if (entry is! Map || entry['family'] is! String || entry['fonts'] is! List) {
      throw StateError('Malformed golden font manifest entry');
    }
    final family = entry['family'] as String;
    final fonts = entry['fonts'] as List;
    if (fonts.length != 1 || fonts.single is! Map || fonts.single['asset'] is! String || found.containsKey(family)) {
      throw StateError('Ambiguous golden font family: $family');
    }
    found[family] = fonts.single['asset'] as String;
  }
  if (found.length != goldenFontAssets.length ||
      goldenFontAssets.entries.any((entry) => found[entry.key] != entry.value)) {
    throw StateError('Golden fonts require the pinned MaterialIcons, JetBrainsMono and Twemoji assets');
  }
  return found;
}

File _runtimeMetadata() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    final candidate = File('${directory.path}/bin/cache/flutter.version.json');
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Cannot locate metadata for the running Flutter test engine');
}

Future<void>? _fontsLoaded;

Future<void> loadGoldenFonts() => _fontsLoaded ??= _loadGoldenFonts();

Future<void> _loadGoldenFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isLinux) throw StateError('Golden screenshots require the pinned Linux environment');
  validateGoldenRuntime(jsonDecode(await _runtimeMetadata().readAsString()) as Map<String, dynamic>);
  final cjk = await File(Platform.environment['XB_GOLDEN_CJK_FONT'] ?? goldenCjkPath).readAsBytes();
  validateGoldenFont('Noto CJK', cjk, goldenCjkSha256);
  await (FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(cjk)))).load();
  final assets = validateGoldenFontManifest(await rootBundle.loadString('FontManifest.json'));
  for (final entry in assets.entries) {
    final data = await rootBundle.load(entry.value);
    validateGoldenFont(entry.key, Uint8List.sublistView(data), goldenAssetSha256[entry.value]!);
    await (FontLoader(entry.key)..addFont(Future.value(data))).load();
  }
  double width(String text) {
    final painter = TextPainter(text: TextSpan(text: text, style: const TextStyle(fontFamily: 'Roboto')),
      textDirection: TextDirection.ltr)..layout();
    final result = painter.width;
    painter.dispose();
    return result;
  }
  if (width('MMMM') <= width('iiii') * 2) {
    throw StateError('Golden text resolved to a box/monospace fallback font');
  }
}

InlineSpan goldenSpan(InlineSpan span, {String inheritedFamily = 'Roboto'}) {
  if (span is! TextSpan) return span;
  final family = span.style?.fontFamily ?? inheritedFamily;
  return TextSpan(
    text: span.text,
    style: (span.style ?? const TextStyle()).copyWith(fontFamily: family),
    children: span.children?.map((child) => goldenSpan(child, inheritedFamily: family)).toList(),
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: span.semanticsLabel,
    semanticsIdentifier: span.semanticsIdentifier,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

Future<void> prepareGoldenFrame(WidgetTester tester) async {
  // The test engine uses Ahem for an unspecified family. Resolve only missing
  // families to the pinned test default, retaining explicit icon/emoji styles.
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject as RenderParagraph;
    paragraph.text = goldenSpan(paragraph.text);
  }
  await tester.pump();
  expect(tester.takeException(), isNull);
}

Future<void> expectXbGolden(WidgetTester tester, Finder target, String path, {bool contrast = false}) async {
  await prepareGoldenFrame(tester);
  // Flutter's guideline matches Text/EditableText, not arbitrary RichText spans.
  // Passing it is not a blanket AA claim for author-styled HTML content.
  if (contrast) await expectLater(tester, meetsGuideline(textContrastGuideline));
  await expectLater(target, matchesGoldenFile(path));
}
