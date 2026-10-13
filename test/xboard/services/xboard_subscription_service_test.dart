/// R4.6 — XboardSubscriptionService 文件化加密订阅：single-flight + force 队列 +
/// 拉密文→解密→putFileProfile + 候选 failOver + 错误分流 + logout/孤儿对账。
library;

import 'dart:async';
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

class _BlockedIndexDatabase extends XboardDatabase {
  _BlockedIndexDatabase() : super(NativeDatabase.memory());
  final indexStarted = Completer<void>();
  final indexGate = Completer<void>();

  @override
  Future<void> putIndex({
    required int profileId,
    required String flavorId,
    required String userIdHash,
  }) async {
    indexStarted.complete();
    await indexGate.future;
    await super.putIndex(
      profileId: profileId,
      flavorId: flavorId,
      userIdHash: userIdHash,
    );
  }
}

/// 内存 fake profile 端口（R4.6：putFileProfile 主路径）。
class _FakePort implements ProfileSyncPort {
  final Map<int, String> profiles = {};
  int _nextId = 100;
  int fileCalls = 0;
  Completer<void>? fileStarted;
  Completer<void>? fileGate;
  final Set<int> failingDeletes = {};
  final List<int> deletedIds = [];

  @override
  Future<int> createAndPutProfile({
    required String url,
    required String label,
  }) async {
    final id = _nextId++;
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
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
    bool Function()? isSessionCurrent,
  }) async {
    fileCalls++;
    final id = profileId ?? _nextId++;
    fileStarted?.complete();
    if (fileGate != null) await fileGate!.future;
    if (isSessionCurrent?.call() == false) {
      throw const ProfileSyncCancelled();
    }
    profiles[id] = 'file:${yamlBytes.length}b';
    return id;
  }

  @override
  Future<void> deleteProfile(int profileId) async {
    deletedIds.add(profileId);
    if (failingDeletes.contains(profileId)) throw StateError('delete failed');
    profiles.remove(profileId);
  }

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
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    hits.add(options.uri.host);
    return handler(options);
  }
}

const String _yaml = 'proxies: []\nproxy-groups: []\nrules: [MATCH,DIRECT]\n';

ResponseBody _plain(String body, {int code = 200}) => ResponseBody.fromString(
  body,
  code,
  headers: {
    Headers.contentTypeHeader: ['text/plain'],
  },
);

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
    when(
      () => service.getSubscribeUrl(),
    ).thenAnswer((_) async => XbResult.success('https://orig.com/thunder/tok'));
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
    FakeTokenStorage? tokenStorage,
    int Function()? sessionRevision,
  }) => XboardSubscriptionService(
    service: service,
    encrypted: enc,
    profilePort: port,
    db: db,
    tokenStorage: tokenStorage ?? FakeTokenStorage(initialToken: 'tokA'),
    sessionRevision: sessionRevision,
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
    final id = await db.findProfileId(
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
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
    final firstId = await db.findProfileId(
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
    await s.sync(force: true);
    final secondId = await db.findProfileId(
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
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
    final s = sut(
      encWith(adapter),
      candidates: ['https://1.1.1.1', 'https://2.2.2.2'],
    );
    final r = await s.sync(force: true);
    expect(r, XbSyncOutcome.ok);
    expect(adapter.hits, ['1.1.1.1', '2.2.2.2']);
  });

  test('onWinnerHost 回调命中 host', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    String? winner;
    final s = sut(
      encWith(adapter),
      candidates: ['https://2.2.2.2'],
      onWinnerHost: (h) => winner = h,
    );
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
    final adapter = _StubAdapter(
      (_) async =>
          ResponseBody.fromString('{"code":40305,"message":"无有效套餐"}', 403),
    );
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.noSubscription);
  });

  test('鉴权失败（后端 40302）→ authExpired', () async {
    // 40301/40302/40303 = 真·token 问题 → authExpired（subscribe 端点权威，无需回查用户信息）。
    final adapter = _StubAdapter(
      (_) async => ResponseBody.fromString(
        '{"code":40302,"message":"invalid token"}',
        403,
      ),
    );
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.authExpired);
  });

  test('套餐过期（后端 40304）→ subscriptionExpired（不再误报 authExpired）', () async {
    // 回归「套餐过期被判登录已过期」：插件对过期套餐回独立码 40304 → subscriptionExpired。
    final adapter = _StubAdapter(
      (_) async => ResponseBody.fromString(
        '{"code":40304,"message":"subscription expired"}',
        403,
      ),
    );
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.subscriptionExpired);
  });

  test('流量耗尽（后端 40307，v1.1.0）→ trafficExhausted', () async {
    final adapter = _StubAdapter(
      (_) async => ResponseBody.fromString(
        '{"code":40307,"message":"traffic exhausted"}',
        403,
      ),
    );
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.trafficExhausted);
  });

  test('内容接口裸 401（无插件码）→ authExpired', () async {
    final adapter = _StubAdapter(
      (_) async => ResponseBody.fromString('unauthorized', 401),
    );
    final s = sut(encWith(adapter), candidates: ['https://1.1.1.1']);
    final r = await s.sync();
    expect(r, XbSyncOutcome.authExpired);
  });

  test('getSubscribeUrl 失败 + 无套餐 → noSubscription', () async {
    when(() => service.getSubscribeUrl()).thenAnswer(
      (_) async => XbResult.failure(
        XbDomainError.network(XbNetworkKind.unknown, 'no url'),
      ),
    );
    when(() => service.getSubscription()).thenAnswer(
      (_) async => XbResult.success(
        const XbDomainSubscription(
          email: 'a@b.com',
          uuid: 'x',
          totalBytes: 0,
          usedBytes: 0,
        ),
      ),
    );
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final r = await s.sync();
    expect(r, XbSyncOutcome.noSubscription);
  });

  test('getSubscribeUrl 失败 + 鉴权过期 → authExpired', () async {
    when(() => service.getSubscribeUrl()).thenAnswer(
      (_) async => XbResult.failure(XbDomainError.unauthorized('过期')),
    );
    when(() => service.getSubscription()).thenAnswer(
      (_) async => XbResult.failure(XbDomainError.unauthorized('过期')),
    );
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final r = await s.sync();
    expect(r, XbSyncOutcome.authExpired);
  });

  test('全候选网络挂 → failed', () async {
    final adapter = _StubAdapter(
      (opts) async => throw DioException(requestOptions: opts),
    );
    final s = sut(
      encWith(adapter),
      candidates: ['https://1.1.1.1', 'https://2.2.2.2'],
    );
    final r = await s.sync(force: true);
    expect(r, XbSyncOutcome.failed);
  });

  test('clearForLogout：删 profile + 清索引', () async {
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    await s.sync(force: true);
    await s.clearForLogout(_hash('tokA'));
    final id = await db.findProfileId(
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
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
    final id = await db.findProfileId(
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
    expect(id, isNull); // 索引未被重建
  });

  test('clearForCurrentUser：不阻塞——在途 sync 慢也立即返回', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    when(() => service.getSubscribeUrl()).thenAnswer((_) async {
      started.complete();
      await gate.future;
      return XbResult.success('https://orig.com/thunder/tok');
    });
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(encWith(adapter));
    final syncing = s.sync(force: true);
    await started.future;
    await s.clearForCurrentUser().timeout(const Duration(milliseconds: 500));
    gate.complete();
    expect(await syncing, XbSyncOutcome.skipped);
    expect(port.fileCalls, 0);
  });

  test('Token 已清后仍按旧归属清理所有重复索引，保留手工与其他账号配置', () async {
    final storage = FakeTokenStorage(initialToken: 'tokA');
    final s = sut(
      encWith(_StubAdapter((_) async => _plain(cipher))),
      tokenStorage: storage,
    );
    port.profiles.addAll({1: 'owned', 2: 'duplicate', 3: 'other', 4: 'manual'});
    port.profiles[5] = 'other flavor';
    await db.putIndex(
      profileId: 1,
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
    await db.putIndex(
      profileId: 2,
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
    await db.putIndex(
      profileId: 3,
      flavorId: 'brandA',
      userIdHash: _hash('tokB'),
    );
    await db.putIndex(
      profileId: 5,
      flavorId: 'brandB',
      userIdHash: _hash('tokA'),
    );
    await storage.deleteToken();

    await s.clearForSessionOwner(_hash('tokA'));

    expect(port.profiles.keys, unorderedEquals([3, 4, 5]));
    expect((await db.allRows()).map((row) => row.profileId), [3, 5]);
    expect(await s.sync(), XbSyncOutcome.skipped);
  });

  test('清理失败保留该索引且继续清理其他归属记录，向调用者报告失败', () async {
    final s = sut(encWith(_StubAdapter((_) async => _plain(cipher))));
    port.profiles.addAll({1: 'owned', 2: 'owned'});
    port.failingDeletes.add(1);
    await db.putIndex(
      profileId: 1,
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
    await db.putIndex(
      profileId: 2,
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );

    await expectLater(
      s.clearForSessionOwner(_hash('tokA')),
      throwsA(isA<StateError>()),
    );

    expect(port.profiles.keys, [1]);
    expect((await db.allRows()).map((row) => row.profileId), [1]);
    expect(port.deletedIds, [1, 2]);
  });

  test('重复结束会话通知复用已完成清理，不删除同归属新会话的 Profile', () async {
    final s = sut(encWith(_StubAdapter((_) async => _plain(cipher))));
    port.profiles[1] = 'old session';
    await db.putIndex(
      profileId: 1,
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );
    await Future.wait([
      s.clearForSessionOwner(_hash('tokA')),
      s.clearForSessionOwner(_hash('tokA')),
    ]);
    expect(port.deletedIds, [1]);
    port.profiles[2] = 'new session';
    await db.putIndex(
      profileId: 2,
      flavorId: 'brandA',
      userIdHash: _hash('tokA'),
    );

    await s.clearForSessionOwner(_hash('tokA'));

    expect(port.profiles.keys, [2]);
    expect(port.deletedIds, [1]);
    expect((await db.allRows()).map((row) => row.profileId), [2]);
  });

  test('A 的订阅 URL 晚到 B 登录后被丢弃，不下载、不写 Profile', () async {
    final storage = FakeTokenStorage(initialToken: 'tokA');
    var revision = 1;
    final started = Completer<void>();
    final url = Completer<XbResult<String>>();
    when(() => service.getSubscribeUrl()).thenAnswer((_) {
      started.complete();
      return url.future;
    });
    final adapter = _StubAdapter((_) async => _plain(cipher));
    final s = sut(
      encWith(adapter),
      tokenStorage: storage,
      sessionRevision: () => revision,
    );
    final syncing = s.sync();
    await started.future;
    await storage.writeToken('tokB');
    revision++;
    url.complete(XbResult.success('https://orig.com/thunder/tokenA'));

    expect(await syncing, XbSyncOutcome.skipped);
    expect(adapter.hits, isEmpty);
    expect(port.fileCalls, 0);
    expect(await db.allRows(), isEmpty);
  });

  test('下载在途退出后晚到结果被丢弃，force 队列不重跑且不回馈 host', () async {
    final downloaded = Completer<void>();
    final response = Completer<ResponseBody>();
    final adapter = _StubAdapter((_) {
      downloaded.complete();
      return response.future;
    });
    var winners = 0;
    final s = sut(encWith(adapter), onWinnerHost: (_) => winners++);
    final syncing = s.sync();
    await downloaded.future;
    final queued = s.sync(force: true);
    await s.clearForSessionOwner(_hash('tokA'));
    response.complete(_plain(cipher));

    expect(await syncing, XbSyncOutcome.skipped);
    expect(await queued, XbSyncOutcome.skipped);
    expect(port.fileCalls, 0);
    expect(winners, 0);
    verify(() => service.getSubscribeUrl()).called(1);
  });

  test('Profile 校验期间退出后晚到写入被 guard 拒绝，不激活或重建索引', () async {
    port.fileStarted = Completer<void>();
    port.fileGate = Completer<void>();
    final s = sut(encWith(_StubAdapter((_) async => _plain(cipher))));
    final syncing = s.sync();
    await port.fileStarted!.future;
    await s.clearForSessionOwner(_hash('tokA'));
    port.fileGate!.complete();

    expect(await syncing, XbSyncOutcome.skipped);
    expect(port.profiles, isEmpty);
    expect(await db.allRows(), isEmpty);
  });

  test('退出发生在外挂索引提交期间，提交后撤销旧 Profile 和晚到索引', () async {
    await db.close();
    final blockedDb = _BlockedIndexDatabase();
    db = blockedDb;
    final s = sut(encWith(_StubAdapter((_) async => _plain(cipher))));
    final syncing = s.sync();
    await blockedDb.indexStarted.future;
    await s.clearForSessionOwner(_hash('tokA'));
    blockedDb.indexGate.complete();

    expect(await syncing, XbSyncOutcome.skipped);
    expect(port.profiles, isEmpty);
    expect(await db.allRows(), isEmpty);
  });

  test('无会话版本注入时下载后仍核对旧 Token 归属，不写入 B 账号', () async {
    final storage = FakeTokenStorage(initialToken: 'tokA');
    final started = Completer<void>();
    final response = Completer<ResponseBody>();
    final adapter = _StubAdapter((_) {
      started.complete();
      return response.future;
    });
    final s = sut(encWith(adapter), tokenStorage: storage);
    final syncing = s.sync();
    await started.future;
    await storage.writeToken('tokB');
    response.complete(_plain(cipher));

    expect(await syncing, XbSyncOutcome.skipped);
    expect(port.fileCalls, 0);
    expect(await db.allRows(), isEmpty);
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
