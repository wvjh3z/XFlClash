import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'identity/brands.dart';

const androidBrandIdentityPath =
    '.dart_tool/xboard/android_brand_identity.json';

/// Gradle consumes only public identity, decoded by the same YAML parser as Dart.
/// Keep a byte digest so a later source edit cannot silently use stale identity.
Map<String, Object> androidBrandIdentity(List<int> bytes, String flavor) {
  final dynamic doc;
  try {
    doc = loadYaml(utf8.decode(bytes));
  } catch (_) {
    throw FormatException('Invalid brand YAML for $flavor');
  }
  if (doc is! YamlMap) {
    throw FormatException('Invalid brand mapping for $flavor');
  }
  final name = doc['appName'];
  final id = doc['appId'];
  if (name is! String ||
      name.trim().isEmpty ||
      name.runes.any(
        (r) =>
            r < 0x20 ||
            (r >= 0x7f && r <= 0x9f) ||
            (r >= 0xd800 && r <= 0xdfff),
      )) {
    throw FormatException('Invalid appName for $flavor');
  }
  if (id is! String ||
      !RegExp(
        r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
      ).hasMatch(id)) {
    throw FormatException('Invalid appId for $flavor');
  }
  final expected = brandIdentities[flavor]?['id'];
  if (expected == null || id != expected) {
    throw FormatException(
      'appId does not match registered identity for $flavor',
    );
  }
  return {
    'appName': name,
    'appId': id,
    'sourceSha256': sha256.convert(bytes).toString(),
  };
}

String generateAndroidBrandIdentities({
  required Directory root,
  required String selectedFlavor,
  required List<int> selectedSource,
}) {
  final brands = <String, Object>{};
  // A clean CI checkout has only the selected secret. A developer checkout may
  // have both; prepare all present identities so Gradle can configure both.
  for (final flavor in {'brand_a', 'brand_b', selectedFlavor}) {
    final file = File('${root.path}/flavors/$flavor/flavor.yaml');
    if (flavor == selectedFlavor) {
      brands[flavor] = androidBrandIdentity(selectedSource, flavor);
    } else if (file.existsSync()) {
      brands[flavor] = androidBrandIdentity(file.readAsBytesSync(), flavor);
    }
  }
  final ids = <String>{};
  for (final identity in brands.values) {
    final id = (identity as Map<String, Object>)['appId'] as String;
    if (ids.contains(id) || ids.contains('$id.dev')) {
      throw const FormatException('Duplicate Android brand appId');
    }
    ids.addAll([id, '$id.dev']);
  }
  return '${jsonEncode({'schemaVersion': 1, 'brands': brands})}\n';
}
