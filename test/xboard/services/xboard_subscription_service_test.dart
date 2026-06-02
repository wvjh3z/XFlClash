/// W6.1/6.2 — XboardSubscriptionService single-flight + force 队列 + 复用 Profile.update + 5 触发点。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' hide AuthState;
import 'package:mocktail/mocktail.dart';

import 'dart:typed_data';

import 'package:fl_clash/xboard/data/xboard_database.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';

import '../../_fixtures/fake_token_storage.dart';

class _MockService extends Mock implements XboardService {}

/// 内存 fake profile 端口。
class _FakePort implements ProfileSyncPort {
  final Map<int, String> profiles = {};
  int _nextId = 100;
  int createCalls = 0;
  int updateCalls = 0;

  @override
  Future<int> createAndPutProfile({required String url, required String label}) async {
    createCalls++;
    final id = _nextId++;
    profiles[id] = url;
    return id;
  }

  @override
  Future<void> updateProfileUrl({required int profileId, required String url}) async {
    updateCalls++;
    profiles[profileId] = url;
  }

  @override
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
  }) async {
    final id = profileId ?? _nextId++;
    profiles[id] = 'file:${yamlBytes.length}b';
    return id;
  }

  @override
  Future<void> deleteProfile(int profileId) async => profiles.remove(profileId);

  @override
  List<int> currentProfileIds() => profiles.keys.toList();
}

void main() {
  late _MockService service;
  late _FakePort port;
  late XboardDatabase db;
  late XboardSubscriptionService sut;

  setUp(() {
    service = _MockService();
    port = _FakePort();
    db = XboardDatabase(NativeDatabase.memory());
    sut = XboardSubscriptionService(
      service: service,
      profilePort: port,
      db: db,
      tokenStorage: FakeTokenStorage(initialToken: 'tokA'),
      flavorId: 'brandA',
    );
    // 默认：getSubscribeUrl 成功 + checkLogin 成功。
    when(() => service.getSubscribeUrl())
        .thenAnswer((_) async => XbResult.success('https://sub.com/s/token123'));
    when(() => service.checkLogin())
        .thenAnswer((_) async => XbResult.success(const XbCheckLogin(isLogin: true)));
  });

  tearDown(() => db.close());

  test('T1 主路径：getSubscribeUrl → checkLogin → createAndPutProfile + 写索引', () async {
    final r = await sut.sync(force: true, checkLogin: true);
    expect(r, XbSyncOutcome.ok);
    expect(port.createCalls, 1);
    verify(() => service.checkLogin()).called(1);
    // 索引已写。
    final id = await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    expect(id, isNotNull);
  });

  test('去重：第二次 sync 命中索引 → updateProfileUrl 不重复 create', () async {
    await sut.sync(force: true);
    await sut.sync(force: true);
    expect(port.createCalls, 1); // 只建一次
    expect(port.updateCalls, greaterThanOrEqualTo(1)); // 第二次走更新
  });

  test('T5 refreshUrl：不调 checkLogin，仅重拼 url 更新', () async {
    await sut.sync(force: true); // 先建立 profile + 缓存 path
    clearInteractions(service);
    await sut.refreshUrl('https://newsub.com');
    verifyNever(() => service.checkLogin()); // T5 不调 checkLogin
    expect(port.profiles.values.any((u) => u.startsWith('https://newsub.com')), isTrue);
  });

  test('single-flight：并发 sync 复用同一 in-flight', () async {
    var calls = 0;
    when(() => service.getSubscribeUrl()).thenAnswer((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return XbResult.success('https://sub.com/s/tok');
    });
    final results = await Future.wait([sut.sync(), sut.sync(), sut.sync()]);
    expect(results, everyElement(XbSyncOutcome.ok));
    // 并发 3 次只触发 1 次实际拉取（force=false 不补刀）。
    expect(calls, 1);
  });

  test('force 队列：in-flight 期间 force=true → 完成后补一次（上限 1）', () async {
    var calls = 0;
    when(() => service.getSubscribeUrl()).thenAnswer((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return XbResult.success('https://sub.com/s/tok');
    });
    final first = sut.sync(); // 启动 in-flight
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final forced = sut.sync(force: true); // in-flight 期间 force
    await Future.wait([first, forced]);
    expect(calls, 2); // 原 1 次 + force 补 1 次
  });

  test('无套餐 → noSubscription', () async {
    when(() => service.getSubscribeUrl())
        .thenAnswer((_) async => XbResult.failure(XbDomainError.network(
            XbNetworkKind.unknown, 'no url')));
    when(() => service.getSubscription()).thenAnswer((_) async => XbResult.success(
        const XbDomainSubscription(
            email: 'a@b.com', uuid: 'x', totalBytes: 0, usedBytes: 0)));
    final r = await sut.sync();
    expect(r, XbSyncOutcome.noSubscription);
  });

  test('鉴权过期 → authExpired', () async {
    when(() => service.getSubscribeUrl())
        .thenAnswer((_) async => XbResult.failure(XbDomainError.unauthorized('过期')));
    when(() => service.getSubscription())
        .thenAnswer((_) async => XbResult.failure(XbDomainError.unauthorized('过期')));
    final r = await sut.sync();
    expect(r, XbSyncOutcome.authExpired);
  });

  test('clearForLogout：删 profile + 清索引', () async {
    await sut.sync(force: true);
    await sut.clearForLogout(_hash('tokA'));
    final id = await db.findProfileId(flavorId: 'brandA', userIdHash: _hash('tokA'));
    expect(id, isNull);
    expect(port.profiles.isEmpty, isTrue);
  });

  test('validateProfileIndex：孤儿索引清理', () async {
    await sut.sync(force: true);
    port.profiles.clear(); // FlClash 侧删了 profile
    await sut.validateProfileIndex();
    expect(await db.allRows(), isEmpty);
  });
}

String _hash(String token) => userIdHashFromToken(token);
