/// W5.8/W6.9/W7.10 — Bootstrap/endpoint/订阅同步/结算 服务层端到端（真机/模拟器）。
///
/// 在目标平台 Flutter 运行时跑核心服务（解密 / 竞速 / single-flight 同步 / retryableCheckout），
/// 验证 crypto / drift 内存索引与受控服务流程；SharedPreferences 和 Profile 端口为测试替身。
library;

import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import '../test/xboard/services/_bootstrap_crypto_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/data/xboard_database.dart';
import 'package:fl_clash/xboard/models/bootstrap_envelope.dart';
import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_local_loader.dart';
import 'package:fl_clash/xboard/services/checkout_service.dart';
import 'dart:typed_data';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';

import '_fake_integration_service.dart';

class _FakePort implements ProfileSyncPort {
  final Map<int, String> profiles = {};
  int _next = 100;
  @override
  Future<int> createAndPutProfile({
    required String url,
    required String label,
  }) async {
    final id = _next++;
    profiles[id] = url;
    return id;
  }

  @override
  Future<void> updateProfileUrl({
    required int profileId,
    required String url,
  }) async {
    profiles[profileId] = url;
  }

  @override
  Future<void> deleteProfile(int profileId) async => profiles.remove(profileId);
  @override
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
    bool Function()? isSessionCurrent,
  }) async {
    if (isSessionCurrent?.call() == false) throw const ProfileSyncCancelled();
    final id = profileId ?? _next++;
    profiles[id] = 'file:$label';
    return id;
  }

  @override
  List<int> currentProfileIds() => profiles.keys.toList();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('W5.8 Bootstrap on-device crypto', () {
    testWidgets('AES-256-GCM 解密 + fallback 加载在真机一致', (t) async {
      // 真机上跑 cryptography 包（platform crypto），验证与单测一致。
      const aesKey = <int>[
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        30,
        31,
        32,
      ];
      final decryptor = BootstrapDecryptor(aesKey: aesKey);
      // 用错误 key 的密文（无法解密）→ decryptError，永不抛。
      const env = BootstrapEnvelopeStub(); // 见下方
      final r = await decryptor.decryptAndValidate(env.value);
      expect(r.isSuccess, isFalse); // 随机密文必失败
      expect(r.failure, isNotNull);
    });

    testWidgets('BootstrapLocalLoader 双损坏 → null（device SharedPreferences）', (
      t,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kBootstrapCacheKey, '{corrupt');
      final loader = BootstrapLocalLoader(
        decryptor: BootstrapDecryptor(aesKey: null),
        prefs: prefs,
        assetLoader: (_) async => '{also bad',
      );
      final result = await loader.loadLocal();
      expect(result.source, BootstrapLocalSource.none);
    });
  });

  group('W5.8 EndpointRaceController on-device', () {
    testWidgets('竞速选可达 + failOver 串行化', (t) async {
      final reachable = {'https://b.com'};
      final c = EndpointRaceController(
        probe: (e) async => reachable.contains(e),
      );
      await c.raceApi(const [
        BootstrapEndpoint(url: 'https://a.com'),
        BootstrapEndpoint(url: 'https://b.com'),
      ]);
      expect(c.currentApiEndpoint, 'https://b.com');
      c.dispose();
    });
  });

  group('W6.9 订阅同步 on-device（drift + single-flight）', () {
    testWidgets('加密同步解密、索引去重与并发合并', (t) async {
      SharedPreferences.setMockInitialValues({});
      final db = XboardDatabase(NativeDatabase.memory());
      final port = _FakePort();
      var downloads = 0;
      final cipher = await encryptPayloadRaw(
        'proxies: []\nproxy-groups: []\nrules: []\n',
        aad: kEncryptedSubscriptionAad,
      );
      final dio = Dio()
        ..httpClientAdapter = _EncryptedAdapter(cipher, () => downloads++);
      addTearDown(() => dio.close(force: true));
      addTearDown(db.close);
      final svc = XboardSubscriptionService(
        service: FakeIntegrationService(),
        encrypted: EncryptedSubscriptionService(
          decryptor: BootstrapDecryptor(aesKey: testAesKey),
          dio: dio,
        ),
        profilePort: port,
        db: db,
        tokenStorage: _MemTokenStorage('tok'),
        flavorId: 'brandA',
      );
      addTearDown(svc.dispose);
      final results = await Future.wait([svc.sync(), svc.sync()]);
      expect(results, everyElement(XbSyncOutcome.ok));
      expect(downloads, 1);
      expect(port.profiles.length, 1);
      await svc.sync(force: true);
      expect(downloads, 2);
      expect(port.profiles.length, 1);
      expect(await db.allRows(), hasLength(1));
    });
  });

  group('W7.10 结算 on-device', () {
    testWidgets('retryableCheckout 复用 pending（completed 不算 pending → 新建）', (
      t,
    ) async {
      final fake = FakeIntegrationService();
      final checkout = CheckoutService(service: fake);
      final r = await checkout.retryableCheckout(
        planId: 1,
        period: XbPlanPeriod.monthly,
        method: 'pm1',
      );
      expect((r as XbSuccess).data, isA<CheckoutPaid>());
      // getOrders 返 completed（非 pending）→ 走新建 createOrder。
      expect(fake.createOrderCalls, 1);
      expect(fake.checkoutCalls, 1);
    });
  });
}

// ── helpers ──

/// 随机 32B 密文 envelope（解密必失败，验证永不抛）。
class BootstrapEnvelopeStub {
  const BootstrapEnvelopeStub();
  BootstrapEnvelope get value => const BootstrapEnvelope(
    schemaVersion: 1,
    // base64 of 28+ 随机字节（nonce+tag 长度够但 GCM 校验失败）。
    encrypted: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  );
}

class _MemTokenStorage implements TokenStorage {
  _MemTokenStorage(this._t);
  final String? _t;
  @override
  Future<String?> readToken() async => _t;
  @override
  Future<void> writeToken(String t) async {}
  @override
  Future<void> deleteToken() async {}
  @override
  Future<void> get ready => Future.value();
}

/// No network: feed a real authenticated envelope to the production decryptor.
class _EncryptedAdapter implements HttpClientAdapter {
  _EncryptedAdapter(this.cipher, this.onDownload);
  final String cipher;
  final void Function() onDownload;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onDownload();
    return ResponseBody.fromString(cipher, 200);
  }

  @override
  void close({bool force = false}) {}
}
