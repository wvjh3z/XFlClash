/// 认证失效清理使用真实端口、内存主库和临时文件，隔离原生内核。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/services/riverpod_profile_sync_port.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSetupAction extends SetupAction {
  final List<bool> statusCalls = [];
  @override
  void build() {}

  @override
  Future<void> updateStatus(bool isStart, {bool isInit = false}) async {
    statusCalls.add(isStart);
  }
}

class _InitialProfileId extends CurrentProfileId {
  _InitialProfileId(this.id);
  final int? id;
  @override
  int? build() => id;
}

void main() {
  late Database db;
  late Directory directory;
  late _FakeSetupAction setup;
  ProviderContainer? container;

  setUp(() async {
    db = Database(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('xb-session-cleanup-');
    setup = _FakeSetupAction();
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    await db.close();
    await directory.delete(recursive: true);
  });

  String pathFor(int id) => '${directory.path}/$id.yaml';

  Future<void> seed(int id, String label) async {
    final profile = Profile(
      id: id,
      label: label,
      autoUpdateDuration: const Duration(days: 1),
    );
    await db.profiles.put(profile.toCompanion());
    await File(pathFor(id)).writeAsString('private-node-data-$id');
  }

  RiverpodProfileSyncPort portFor({
    int? selectedId,
    bool started = true,
    Future<String> Function(int)? profilePath,
  }) {
    final provider = Provider<RiverpodProfileSyncPort>(
      (ref) => RiverpodProfileSyncPort(
        ref,
        profileDatabase: db,
        profilePath: profilePath ?? ((id) async => pathFor(id)),
      ),
    );
    container = ProviderContainer(
      overrides: [
        currentProfileIdProvider.overrideWith(
          () => _InitialProfileId(selectedId),
        ),
        isStartProvider.overrideWith((ref) => started),
        setupActionProvider.overrideWith(() => setup),
        profilesStreamProvider.overrideWith(
          (ref) => db.profilesDao.query().watch(),
        ),
      ],
    );
    // 真实 UI/底座持续观察选择态；保留 autoDispose provider，避免夹具在跨越 I/O await 后
    // 重建并重新返回初始 selectedId，掩盖已经完成的清选择操作。
    container!.listen(currentProfileIdProvider, (_, _) {});
    return container!.read(provider);
  }

  test('正在使用被清理的账号 Profile 时停用并清选择，等待 DB 和文件删除', () async {
    await seed(1, 'account');
    final port = portFor(selectedId: 1);

    await port.deleteProfile(1);

    expect(setup.statusCalls, [false]);
    expect(container!.read(currentProfileIdProvider), isNull);
    expect(await db.profilesDao.query().get(), isEmpty);
    expect(await File(pathFor(1)).exists(), isFalse);
  });

  test('正在使用手动 Profile 时保持连接、选择、手工 DB 和文件', () async {
    await seed(1, 'account');
    await seed(2, 'manual');
    final port = portFor(selectedId: 2);

    await port.deleteProfile(1);

    expect(setup.statusCalls, isEmpty);
    expect(container!.read(currentProfileIdProvider), 2);
    expect((await db.profilesDao.query().get()).map((p) => p.id), [2]);
    expect(await File(pathFor(1)).exists(), isFalse);
    expect(await File(pathFor(2)).exists(), isTrue);
  });

  test('已断开连接时不重复调用停止，清理当前选择和持久记录', () async {
    await seed(1, 'account');
    final port = portFor(selectedId: 1, started: false);

    await port.deleteProfile(1);

    expect(setup.statusCalls, isEmpty);
    expect(container!.read(currentProfileIdProvider), isNull);
    expect(await db.profilesDao.query().get(), isEmpty);
  });

  test('明文文件路径解析失败向调用者报告，主库记录保留供恢复', () async {
    await seed(1, 'account');
    final port = portFor(
      profilePath: (_) async =>
          throw const FileSystemException('test I/O failure'),
    );

    await expectLater(
      port.deleteProfile(1),
      throwsA(isA<FileSystemException>()),
    );

    expect((await db.profilesDao.query().get()).map((p) => p.id), [1]);
    expect(await File(pathFor(1)).exists(), isTrue);
    expect(setup.statusCalls, isEmpty);
  });

  test('旧 provider 已释放后仍完成晚到补偿的 DB 和文件删除，不访问失效 Ref', () async {
    await seed(1, 'late account profile');
    final port = portFor(selectedId: 1);
    container!.dispose();
    container = null;

    await port.deleteProfile(1);

    expect(await db.profilesDao.query().get(), isEmpty);
    expect(await File(pathFor(1)).exists(), isFalse);
    expect(setup.statusCalls, isEmpty);
  });
}
