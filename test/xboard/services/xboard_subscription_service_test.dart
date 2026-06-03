/// R4.6 — XboardSubscriptionService 文件化加密订阅：single-flight + force 队列 +
/// 拉密文→解密→putFileProfile + 候选 failOver + 错误分流 + logout/孤儿对账。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/data/xboard_database.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';

import '../../_fixtures/fake_token_storage.dart';
import '_bootstrap_crypto_helper.dart';

class _MockService extends Mock implements XboardService {}

/// 内存 fake profile 端口（R4.6：putFileProfile 主路径）。
class _FakePort implements ProfileSyncPort {
  final Map<int, String> profiles = {};
  int _nextId = 100;
  int fileCalls = 0;

  @override
  Future<int> createAndPutProfile(
      {required String url, required String label}) async {
    final id = _nextId++;
    profiles[id] = url;
    return id;
  }

  @override
  Future<void> updateProfileUrl(
      {required int profileId, required String url}) async {
    profiles[profileId] = url;
  }

  @override
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
  }) async {
    fileCalls++;
    final id = profileId ?? _nextId++;
    profiles[id] = 'file:${yamlBytes.length}b';
    return id;
  }

  @override
  Future<void> deleteProfile(int profileId) async => profiles.remove(profileId);

  @override
  List<int> currentProfileIds() => profiles.keys.toList();
}

/// 可编程 dio adapter（按 host 返回 canned 密文 / 状态码 / 抛错）。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<String> hits = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    hits.add(options.uri.host);
    return handler(options);
  }
}

const String _yaml = 'proxies: []\nproxy-groups: []\nrules: [MATCH,DIRECT]\n';

ResponseBody _plain(String body, {int code = 200}) =>
    ResponseBody.fromString(body, code, headers: {
      Headers.contentTypeHeader: ['text/plain']
    });

void main() {
  late _MockService service;
  late _FakePort port;
  late XboardDatabase db;
  late String cipher;

  setUpAll(() async {
    cipher = await encryptPayloadRaw(_yaml, aad: kEncryptedSubscriptionAad);
  });

  setUp(() {
    service = _MockService();
    port = _FakePort();
    db = XboardDatabase(NativeDatabase.memory());
    when(() => service.getSubscribeUrl())
        .thenAnswer((_) async => XbResult.success('https://orig.com/thunder/tok'));
  });

  tearDown(() => db.close());

  /// 用 stub adapter 构造真实 EncryptedSubscriptionService（testAesKey 解密）。
  EncryptedSubscriptionService encWith(_StubAdapter adapter) {
    final dio = Dio()..httpClientAdapter = adapter;
    return EncryptedSubscriptionService(
      decryptor: BootstrapDecryptor(aesKey: testAesKey),
      dio: dio,
    );
  }

  XboardSubscriptionService sut(
    EncryptedSubscriptionService enc, {
    List<String> candidates = const [],
    void Function(String)? onWinnerHost,
  }) =>
      XboardSubscriptionService(
        service: service,
        encrypted: enc,
        profilePort: port,
        db: db,
        tokenStorage: FakeTokenStorage(initialToken: 'tokA'),
        subscriptionCandidates: () => candidates,
        onWinnerHost: onWinnerHost,
        flavorId: 'brandA',
      );

  test('主路径：getSubscribeUrl → 拉密文解密 → putFileProfile + 写索引', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final r = await s.sync(force: true);
    expect(r, XbSyncOutcome.ok);
    expect(port.fileCalls, 1);
    final id = await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    expect(id, isNotNull);
  });

  test('不调 checkLogin（已移除）', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    await s.sync(force: true);
    verifyNever(() => service.checkLogin());
  });

  test('去重：第二次 sync 命中索引 → 原地覆写同一 profile（不新建）', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    await s.sync(force: true);
    final firstId =
        await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    await s.sync(force: true);
    final secondId =
        await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    expect(secondId, firstId); // 同一 profile
    expect(port.profiles.length, 1); // 没新增
    expect(port.fileCalls, 2);
  });

  test('候选 failOver：首发挂 → 顺位第二个成功', () async {
    final adapter = _StubAdapter((opts) async {
      if (opts.uri.host == '1.1.1.1') {
        throw DioException(requestOptions: opts);
      }
      return _plain(cipher);
    });
    final s = sut(encWith(adapter),
        candidates: ['https://1.1.1.1', 'https://2.2.2.2']);
    final r = await s.sync(force: true);
    expect(r, XbSyncOutcome.ok);
    expect(adapter.hits, ['1.1.1.1', '2.2.2.2']);
  });

  test('onWinnerHost 回调命中 host', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    String? winner;
    final s = sut(encWith(adapter),
        candidates: ['https://2.2.2.2'], onWinnerHost: (h) => winner = h);
    await s.sync(force: true);
    expect(winner, 'https://2.2.2.2');
  });

  test('single-flight：并发 sync 复用同一 in-flight（force=false 不补刀）', () async {
    var calls = 0;
    when(() => service.getSubscribeUrl()).thenAnswer((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return XbResult.success('https://orig.com/thunder/tok');
    });
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final results = await Future.wait([s.sync(), s.sync(), s.sync()]);
    expect(results, everyElement(XbSyncOutcome.ok));
    expect(calls, 1);
  });

  test('force 队列：in-flight 期间 force → 完成后补一次（上限 1）', () async {
    var calls = 0;
    when(() => service.getSubscribeUrl()).thenAnswer((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return XbResult.success('https://orig.com/thunder/tok');
    });
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final first = s.sync();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final forced = s.sync(force: true);
    await Future.wait([first, forced]);
    expect(calls, 2);
  });

  test('无套餐（后端 40305）→ noSubscription', () async {
    final adapter = _StubAdapter((_) async => ResponseBody.fromString(
        '{"code":40305,"message":"无有效套餐"}', 403));
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.noSubscription);
  });

  test('鉴权过期（后端 40302）→ authExpired', () async {
    final adapter = _StubAdapter((_) async => ResponseBody.fromString(
        '{"code":40302,"message":"invalid token"}', 403));
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.authExpired);
  });

  test('getSubscribeUrl 失败 + 无套餐 → noSubscription', () async {
    when(() => service.getSubscribeUrl())
        .thenAnswer((_) async => XbResult.failure(
            XbDomainError.network(XbNetworkKind.unknown, 'no url')));
    when(() => service.getSubscription()).thenAnswer((_) async =>
        XbResult.success(const XbDomainSubscription(
            email: 'a@b.com', uuid: 'x', totalBytes: 0, usedBytes: 0)));
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final r = await s.sync();
    expect(r, XbSyncOutcome.noSubscription);
  });

  test('getSubscribeUrl 失败 + 鉴权过期 → authExpired', () async {
    when(() => service.getSubscribeUrl())
        .thenAnswer((_) async => XbResult.failure(XbDomainError.unauthorized('过期')));
    when(() => service.getSubscription())
        .thenAnswer((_) async => XbResult.failure(XbDomainError.unauthorized('过期')));
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final r = await s.sync();
    expect(r, XbSyncOutcome.authExpired);
  });

  test('全候选网络挂 → failed', () async {
    final adapter = _StubAdapter((opts) async =>
        throw DioException(requestOptions: opts));
    final s = sut(encWith(adapter),
        candidates: ['https://1.1.1.1', 'https://2.2.2.2']);
    final r = await s.sync(force: true);
    expect(r, XbSyncOutcome.failed);
  });

  test('clearForLogout：删 profile + 清索引', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    await s.sync(force: true);
    await s.clearForLogout(_hash('tokA'));
    final id = await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    expect(id, isNull);
    expect(port.profiles.isEmpty, isTrue);
  });

  test('clearForCurrentUser：θ-8 登出后 sync 被 skip（不重建孤儿）', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    await s.sync(force: true); // 建立 profile
    expect(port.fileCalls, 1);
    await s.clearForCurrentUser(); // 删 profile + 置 _loggingOut
    // 登出后再 sync → skip，不重建 profile。
    final r = await s.sync(force: true);
    expect(r, XbSyncOutcome.skipped);
    expect(port.fileCalls, 1); // 未再写文件
    final id = await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    expect(id, isNull); // 索引未被重建
  });

  test('validateProfileIndex：孤儿索引清理', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    await s.sync(force: true);
    port.profiles.clear(); // FlClash 侧删了 profile
    await s.validateProfileIndex();
    expect(await db.allRows(), isEmpty);
  });
}

String _hash(String token) => userIdHashFromToken(token);
