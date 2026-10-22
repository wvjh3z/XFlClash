import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/xboard/sdk/secure_storage_token_storage.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The platform fixture exercises false/throw/silent-loss below the Dart cache.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _recordA = '${kXbAccessTokenKey}_brand_a_record_v2';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  bool reject = false;
  bool throwWrite = false;
  bool loseWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (throwWrite) throw StateError('fixture preferences unavailable');
    if (reject) return false;
    if (loseWrite) return true;
    return super.setValue(valueType, key, value);
  }
}

class _SecureFixture {
  final values = <String, String>{};
  final calls = <MethodCall>[];
  bool failRead = false;
  bool failWrite = false;
  bool dropWrite = false;
  bool failDelete = false;
  bool dropDelete = false;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  Completer<void>? deleteGate;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map;
    final key = args['key'] as String;
    switch (call.method) {
      case 'read':
        if (failRead) throw PlatformException(code: 'fixture_read');
        return values[key];
      case 'write':
        if (failWrite) throw PlatformException(code: 'fixture_write');
        final gate = writeGate;
        if (gate != null) {
          writeGate = null;
          writeStarted?.complete();
          await gate.future;
        }
        if (!dropWrite) values[key] = args['value'] as String;
        return null;
      case 'delete':
        if (failDelete) throw PlatformException(code: 'fixture_delete');
        final gate = deleteGate;
        if (gate != null) {
          deleteGate = null;
          await gate.future;
        }
        if (!dropDelete) values.remove(key);
        return null;
      default:
        throw StateError('Unexpected storage call');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SecureFixture secure;
  late _Preferences preferences;
  var degradations = 0;
  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));

  Future<TokenStorage> open({
    String brand = 'brand_a',
    Duration? timeout,
  }) async {
    final storage = await SecureStorageTokenStorage.create(
      fallbackAesKey: key,
      namespace: brand,
      operationTimeout: timeout ?? const Duration(seconds: 1),
      onDegraded: () => degradations++,
    );
    await storage.ready;
    return storage;
  }

  Future<Map<String, dynamic>> record() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return jsonDecode(prefs.getString(_recordA)!) as Map<String, dynamic>;
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.resetStatic();
    preferences = _Preferences();
    SharedPreferencesStorePlatform.instance = preferences;
    secure = _SecureFixture();
    degradations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, secure.handle);
  });

  tearDown(() {
    XBoardSDK.instance.dispose();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'locked plugin options use traditional macOS keychain and Android encryption',
    () {
      const storage = SecureStorageTokenStorage.defaultStorage;
      expect(storage.mOptions.toMap()['usesDataProtectionKeychain'], 'false');
      expect(storage.aOptions.toMap()['encryptedSharedPreferences'], 'true');
      expect(storage.aOptions.toMap()['migrateOnAlgorithmChange'], 'false');
      expect(storage.aOptions.toMap()['resetOnError'], 'false');
    },
  );

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.linux,
  ]) {
    test(
      '$platform: probe, save, restart, account switch and logout',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final first = await open();
        expect(
          secure.calls.map((c) => c.method),
          containsAll(['write', 'read', 'delete']),
        );
        expect(secure.values, isEmpty, reason: 'probe must clean up');
        await first.writeToken('fixture-a');
        expect(await first.readToken(), 'fixture-a');
        final second = await open();
        expect(await second.readToken(), 'fixture-a');
        await second.writeToken('fixture-b');
        expect(await (await open()).readToken(), 'fixture-b');
        await second.deleteToken();
        expect(await (await open()).readToken(), isNull);
        expect(degradations, 0);
      },
    );

    test(
      '$platform: read succeeds but writes fail -> durable encrypted fallback',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        secure.failWrite = true;
        final storage = await open();
        await storage.writeToken('fixture-a');
        expect(await storage.readToken(), 'fixture-a');
        expect(degradations, 1);
        expect(
          jsonEncode(await preferences.getAll()),
          isNot(contains('fixture-a')),
        );
        secure.failWrite = false;
        secure.values[kXbAccessTokenKey] = 'stale-account';
        expect(await (await open()).readToken(), 'fixture-a');
        await storage.deleteToken();
        expect(await (await open()).readToken(), isNull);
      },
    );
  }

  test(
    'probe rejects successful write/delete calls that do not persist',
    () async {
      secure.dropWrite = true;
      final storage = await open();
      await storage.writeToken('fixture-a');
      expect((await record())['backend'], 'fallback');
      expect(await storage.readToken(), 'fixture-a');
    },
  );

  test('probe rejects deletion that leaves the probe behind', () async {
    secure.dropDelete = true;
    await open();
    expect((await record())['backend'], 'fallback');
    expect(degradations, 1);
  });

  test(
    'write failure after initialization switches permanently to fallback',
    () async {
      final storage = await open();
      await storage.writeToken('fixture-a');
      secure.failWrite = true;
      await storage.writeToken('fixture-b');
      secure.failWrite = false;
      expect(await (await open()).readToken(), 'fixture-b');
      expect((await record())['backend'], 'fallback');
    },
  );

  test(
    'runtime read failure migrates only the verified current token',
    () async {
      final storage = await open();
      await storage.writeToken('fixture-a');
      secure.failRead = true;
      expect(await storage.readToken(), 'fixture-a');
      expect((await record())['backend'], 'fallback');
      secure.failRead = false;
      expect(await (await open()).readToken(), 'fixture-a');
    },
  );

  test(
    'cold read failure cannot resurrect old secure credentials later',
    () async {
      await (await open()).writeToken('fixture-a');
      secure.failRead = true;
      final restart = await open();
      expect(await restart.readToken(), isNull);
      secure.failRead = false;
      expect(await (await open()).readToken(), isNull);
      await restart.writeToken('fixture-b');
      expect(await (await open()).readToken(), 'fixture-b');
    },
  );

  test('logout stays logged out when native deletion fails', () async {
    final storage = await open();
    await storage.writeToken('fixture-a');
    secure.failDelete = true;
    await storage.deleteToken();
    expect(secure.values.values, contains('fixture-a'));
    expect(await (await open()).readToken(), isNull);
    secure.failDelete = false;
    expect(await (await open()).readToken(), isNull);
  });

  test(
    'late timed-out write cannot undo logout or overwrite new login',
    () async {
      final storage = await open(timeout: const Duration(milliseconds: 30));
      final release = Completer<void>();
      secure.writeGate = release;
      secure.writeStarted = Completer<void>();
      final saving = storage.writeToken('late-account');
      await secure.writeStarted!.future;
      await saving;
      expect((await record())['backend'], 'fallback');
      await storage.deleteToken();
      await storage.writeToken('current-account');
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await (await open()).readToken(), 'current-account');
      expect(secure.values.values, isNot(contains('late-account')));
    },
  );

  test('native deletion hanging does not block logout or next login', () async {
    final storage = await open();
    await storage.writeToken('fixture-a');
    final release = Completer<void>();
    secure.deleteGate = release;
    try {
      await storage.deleteToken().timeout(const Duration(milliseconds: 200));
      expect(await (await open()).readToken(), isNull);
      await storage.writeToken('fixture-b');
    } finally {
      release.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(await (await open()).readToken(), 'fixture-b');
  });

  test('queued write then delete leaves empty session', () async {
    final storage = await open();
    final release = Completer<void>();
    secure.writeGate = release;
    secure.writeStarted = Completer<void>();
    final saving = storage.writeToken('fixture-a');
    await secure.writeStarted!.future;
    final deleting = storage.deleteToken();
    release.complete();
    await Future.wait([saving, deleting]);
    expect(await (await open()).readToken(), isNull);
  });

  for (final failure in ['false', 'throw', 'silent loss']) {
    test(
      'preference commit $failure rejects login and preserves prior record',
      () async {
        final storage = await open();
        await storage.writeToken('fixture-a');
        preferences.reject = failure == 'false';
        preferences.throwWrite = failure == 'throw';
        preferences.loseWrite = failure == 'silent loss';
        await expectLater(storage.writeToken('fixture-b'), throwsStateError);
        preferences.reject = preferences.throwWrite = preferences.loseWrite =
            false;
        expect(await (await open()).readToken(), 'fixture-a');
        await storage.writeToken('fixture-c');
        expect(await (await open()).readToken(), 'fixture-c');
      },
    );
  }

  test('fallback commit failure is not treated as login success', () async {
    secure.failWrite = true;
    final storage = await open();
    preferences.reject = true;
    await expectLater(storage.writeToken('fixture-a'), throwsStateError);
    preferences.reject = false;
    expect(await (await open()).readToken(), isNull);
  });

  test('failed logout persistence reports failure and can retry', () async {
    final storage = await open();
    await storage.writeToken('fixture-a');
    preferences.reject = true;
    await expectLater(storage.deleteToken(), throwsStateError);
    preferences.reject = false;
    expect(await (await open()).readToken(), 'fixture-a');
    await storage.deleteToken();
    expect(await (await open()).readToken(), isNull);
  });

  test(
    'initial preference outage retries on the same storage instance',
    () async {
      preferences.reject = true;
      final storage = await SecureStorageTokenStorage.create(
        fallbackAesKey: key,
        namespace: 'brand_a',
      );
      await expectLater(storage.ready, throwsStateError);
      preferences.reject = false;
      await storage.writeToken('fixture-a');
      expect(await storage.readToken(), 'fixture-a');
    },
  );

  test('brands cannot read or delete each others new sessions', () async {
    final a = await open();
    final b = await open(brand: 'brand_b');
    await a.writeToken('brand-a-account');
    await b.writeToken('brand-b-account');
    await a.deleteToken();
    expect(await (await open()).readToken(), isNull);
    expect(await (await open(brand: 'brand_b')).readToken(), 'brand-b-account');
  });

  test(
    'legacy non-mac secure token migrates and cannot return after logout',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      secure.values[kXbAccessTokenKey] = 'legacy-account';
      final storage = await open();
      expect(await storage.readToken(), 'legacy-account');
      secure.failDelete = true;
      await storage.deleteToken();
      expect(await (await open()).readToken(), isNull);
    },
  );

  test('mac does not adopt unowned legacy shared key', () async {
    secure.values[kXbAccessTokenKey] = 'unowned-account';
    expect(await (await open()).readToken(), isNull);
    expect(
      secure.calls.where(
        (c) => (c.arguments as Map)['key'] == kXbAccessTokenKey,
      ),
      isEmpty,
    );
  });

  test(
    'legacy encrypted fallback migrates before probing native storage',
    () async {
      await AesEncryptedSharedPrefsTokenStorage(
        aesKey: key,
      ).writeToken('legacy-encrypted');
      final storage = await open();
      expect(await storage.readToken(), 'legacy-encrypted');
      expect(secure.calls, isEmpty);
      await storage.deleteToken();
      expect(await (await open()).readToken(), isNull);
    },
  );

  test(
    'another brands legacy ciphertext is not deleted on failed migration',
    () async {
      final otherKey = Uint8List.fromList(List.filled(32, 99));
      await AesEncryptedSharedPrefsTokenStorage(
        aesKey: otherKey,
      ).writeToken('other-brand-account');
      final storage = await open();
      expect(await storage.readToken(), isNull);
      await storage.deleteToken();
      await Future<void>.delayed(Duration.zero);
      expect(
        await AesEncryptedSharedPrefsTokenStorage(aesKey: otherKey).readToken(),
        'other-brand-account',
      );
    },
  );

  test(
    'stale memory cannot recover a newer account after a read failure',
    () async {
      final first = await open();
      await first.writeToken('fixture-a');
      await (await open()).writeToken('fixture-b');
      secure.failRead = true;
      expect(await first.readToken(), isNull);
      expect(await (await open()).readToken(), isNull);
    },
  );

  test(
    'fallback sessions remain isolated even with the same AES key',
    () async {
      secure.failWrite = true;
      final a = await open();
      final b = await open(brand: 'brand_b');
      await a.writeToken('fixture-a');
      await b.writeToken('fixture-b');
      await a.deleteToken();
      expect(await (await open()).readToken(), isNull);
      expect(await (await open(brand: 'brand_b')).readToken(), 'fixture-b');
    },
  );

  test('corrupt record does not fall back to stale legacy key', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    secure.values[kXbAccessTokenKey] = 'stale-account';
    await preferences.setValue('String', 'flutter.$_recordA', '{broken');
    expect(await (await open()).readToken(), isNull);
    expect(secure.calls, isEmpty);
  });

  test('corrupt ciphertext is retired and new login recovers', () async {
    secure.failWrite = true;
    final storage = await open();
    await storage.writeToken('fixture-a');
    final data = await record();
    data['value'] = 'invalid-base64';
    await preferences.setValue('String', 'flutter.$_recordA', jsonEncode(data));
    expect(await storage.readToken(), isNull);
    await storage.writeToken('fixture-b');
    expect(await (await open()).readToken(), 'fixture-b');
  });

  test(
    'real SDK saves only persisted credentials and restores logout state',
    () async {
      final storage = await open();
      final sdk = XBoardSDK.instance;
      await sdk.initialize(
        'https://fixture.invalid',
        customStorage: storage,
        enableLogging: false,
      );
      final revision = sdk.authSession.revision;
      preferences.reject = true;
      await expectLater(
        sdk.saveTokenIfSession('fixture-a', revision),
        throwsStateError,
      );
      expect(sdk.authSession.revision, revision);
      expect(sdk.isAuthenticated, isFalse);
      preferences.reject = false;
      secure.failWrite = true;
      final saved = await sdk.saveTokenIfSession('fixture-b', revision);
      expect(saved, isNotNull);
      expect(sdk.isAuthenticated, isTrue);
      expect(await sdk.getToken(), 'fixture-b');
      expect(await sdk.clearTokenIfSession(saved!.revision), isTrue);
      sdk.dispose();
      await sdk.initialize(
        'https://fixture.invalid',
        customStorage: await open(),
        enableLogging: false,
      );
      expect(sdk.isAuthenticated, isFalse);
    },
  );

  test(
    'invalid configuration cannot persist plaintext or report login success',
    () async {
      const storage = UnavailableTokenStorage();
      expect(await storage.readToken(), isNull);
      await expectLater(storage.writeToken('fixture-a'), throwsStateError);
      await expectLater(storage.deleteToken(), throwsStateError);
      expect(await preferences.getAll(), isEmpty);
    },
  );
}
