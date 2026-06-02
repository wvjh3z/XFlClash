/// W5.6.6 — BootstrapLocalLoader：缓存命中 / fallback 兜底 / 双双损坏返 null / 损坏 delete。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_local_loader.dart';

import '_bootstrap_crypto_helper.dart';

void main() {
  late BootstrapDecryptor decryptor;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    decryptor = BootstrapDecryptor(aesKey: testAesKey);
  });

  BootstrapLocalLoader loader({Future<String> Function(String)? asset}) =>
      BootstrapLocalLoader(
        decryptor: decryptor,
        prefs: prefs,
        assetLoader: asset ?? (_) => throw Exception('no asset'),
      );

  test('缓存命中 → source=cache', () async {
    final env = await validEnvelope(api: ['https://cached.com']);
    await prefs.setString(kBootstrapCacheKey, jsonEncode(env.toJson()));
    final r = await loader().loadLocal();
    expect(r.source, BootstrapLocalSource.cache);
    expect(r.payload!.apiUrls, ['https://cached.com']);
  });

  test('无缓存 → fallback 资产兜底', () async {
    final env = await validEnvelope(api: ['https://fallback.com']);
    final r = await loader(asset: (_) async => jsonEncode(env.toJson())).loadLocal();
    expect(r.source, BootstrapLocalSource.fallbackAsset);
    expect(r.payload!.apiUrls, ['https://fallback.com']);
  });

  test('缓存损坏 → delete + 走 fallback', () async {
    await prefs.setString(kBootstrapCacheKey, '{bad json');
    final env = await validEnvelope();
    final r = await loader(asset: (_) async => jsonEncode(env.toJson())).loadLocal();
    expect(r.source, BootstrapLocalSource.fallbackAsset);
    expect(prefs.getString(kBootstrapCacheKey), isNull); // 已删
  });

  test('缓存 + fallback 双双损坏 → null（F15）', () async {
    await prefs.setString(kBootstrapCacheKey, '{bad');
    final r = await loader(asset: (_) async => '{also bad').loadLocal();
    expect(r.source, BootstrapLocalSource.none);
    expect(r.payload, isNull);
  });

  test('writeCache 后能再读到', () async {
    final env = await validEnvelope(api: ['https://w.com']);
    await loader().writeCache(env);
    final r = await loader().loadLocal();
    expect(r.source, BootstrapLocalSource.cache);
    expect(r.payload!.apiUrls, ['https://w.com']);
  });
}
