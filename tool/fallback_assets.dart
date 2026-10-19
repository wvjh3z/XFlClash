import 'package:yaml/yaml.dart';
import 'dart:convert';
import 'package:fl_clash/xboard/models/bootstrap_envelope.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';

const fallbackBegin = '    # xboard-fallback-assets:begin';
const fallbackEnd = '    # xboard-fallback-assets:end';

Future<void> verifyFallbackInput(String envelope, List<int> key) async {
  try {
    final parsed = BootstrapEnvelope.fromJson(
      jsonDecode(envelope) as Map<String, dynamic>,
    );
    final result = await BootstrapDecryptor(
      aesKey: key,
    ).decryptAndValidate(parsed);
    if (!result.isSuccess) throw const FormatException();
  } catch (_) {
    // Do not include ciphertext, key, plaintext endpoints or parser excerpts.
    throw const FormatException(
      'Fallback cannot be authenticated and decoded into valid endpoints',
    );
  }
}

/// Own only the marked asset entry; keep all other pubspec bytes unchanged.
String injectFallbackAsset(String source, String flavor) {
  if (!{'brand_a', 'brand_b'}.contains(flavor)) {
    throw const FormatException('Unsupported fallback brand');
  }
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  final text = source.replaceAll('\r\n', '\n');
  final pattern = RegExp(
    '^${RegExp.escape(fallbackBegin)}\n.*?^${RegExp.escape(fallbackEnd)}',
    multiLine: true,
    dotAll: true,
  );
  if (pattern.allMatches(text).length != 1 ||
      fallbackBegin.allMatches(text).length != 1 ||
      fallbackEnd.allMatches(text).length != 1) {
    throw const FormatException('Invalid fallback asset markers');
  }
  final replacement =
      '$fallbackBegin\n'
      '    - flavors/$flavor/assets/fallback.bin\n$fallbackEnd';
  final result = text.replaceFirst(pattern, replacement);
  final yaml = loadYaml(result) as YamlMap;
  final assets = (yaml['flutter'] as YamlMap)['assets'] as YamlList;
  final brandAssets = assets
      .where((entry) => entry.toString().contains('flavors/'))
      .toList();
  if (brandAssets.length != 1 ||
      brandAssets.single != 'flavors/$flavor/assets/fallback.bin') {
    throw const FormatException('Unexpected extra brand assets');
  }
  return result.replaceAll('\n', newline);
}
