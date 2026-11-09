import 'dart:async';

import 'package:drift/native.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

class _Core extends Mock implements CoreHandlerInterface {}

// Real ProxiesAction -> ProfilesAction -> Profiles -> SQLite. Only Core I/O is
// held, so a late reply can be released after changing the active profile.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.Database database;
  late ProviderContainer container;
  late _Core core;
  late bool disposed;
  setUpAll(() async {
    registerFallbackValue(const ChangeProxyParams(groupName: 'G', proxyName: 'P'));
    await AppLocalizations.load(const Locale('en'));
  });
  setUp(() async {
    disposed = false;
    database = db.Database(NativeDatabase.memory());
    db.database = database;
    for (final profile in [
      const Profile(id: 101, label: 'A', autoUpdateDuration: Duration.zero,
          selectedMap: {'G': 'A-old'}),
      const Profile(id: 202, label: 'B', autoUpdateDuration: Duration.zero,
          selectedMap: {'G': 'B-own'}),
    ]) {
      await database.profiles.put(profile.toCompanion());
    }
    core = _Core();
    container = ProviderContainer(overrides: [
      coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      currentProfileIdProvider.overrideWithBuild((_, _) => 101),
    ]);
    container.listen(profilesProvider, (_, _) {});
    await container.read(profilesStreamProvider.future);
    expect(container.read(profilesProvider), hasLength(2));
    when(() => core.changeProxy(any())).thenAnswer(
      (_) async => const ChangeProxyResult(changed: false),
    );
  });
  tearDown(() async {
    if (!disposed) container.dispose();
    await database.close();
  });

  Future<Map<int, String?>> persisted() async {
    final observed = {for (final p in container.read(profilesProvider))
      p.id: p.selectedMap['G']};
    final rows = await database.profilesDao.query().watch().firstWhere((rows) =>
      rows.length == observed.length &&
      rows.every((p) => p.selectedMap['G'] == observed[p.id]));
    return {for (final p in rows) p.id: p.selectedMap['G']};
  }
  ProxiesAction action() => container.read(proxiesActionProvider.notifier);

  test('control: a successful selection persists in its profile', () async {
    await action().changeProxy(groupName: 'G', proxyName: 'A-new');
    expect(await persisted(), {101: 'A-new', 202: 'B-own'});
  });
  test('control: ordinary failure rolls back the same profile', () async {
    when(() => core.changeProxy(any())).thenThrow(StateError('controlled failure'));
    await action().changeProxy(groupName: 'G', proxyName: 'A-new');
    expect(await persisted(), {101: 'A-old', 202: 'B-own'});
  });
  test('late A failure must not write into newly selected profile B', () async {
    final entered = Completer<void>();
    final reply = Completer<ChangeProxyResult>();
    when(() => core.changeProxy(any())).thenAnswer((_) {
      entered.complete();
      return reply.future;
    });
    final pending = action().changeProxy(groupName: 'G', proxyName: 'A-new');
    await entered.future;
    container.read(currentProfileIdProvider.notifier).value = 202;
    expect(container.read(currentProfileProvider)?.id, 202);
    reply.completeError(StateError('late A failure'));
    await pending;
    final stored = await persisted();
    debugPrint('late-A persisted selections: $stored');
    expect(stored[202], 'B-own', reason: 'A reply cannot mutate profile B');
  });
  test('older failure must not roll back a newer accepted selection', () async {
    final reply = Completer<ChangeProxyResult>();
    var calls = 0;
    when(() => core.changeProxy(any())).thenAnswer((_) => ++calls == 1
      ? reply.future
      : Future.value(const ChangeProxyResult(changed: false)));
    final first = action().changeProxy(groupName: 'G', proxyName: 'A-first');
    await action().changeProxy(groupName: 'G', proxyName: 'A-second');
    expect(container.read(currentProfileProvider)?.selectedMap['G'], 'A-second');
    reply.completeError(StateError('older selection failed'));
    await first;
    final stored = await persisted();
    debugPrint('late-older persisted selections: $stored');
    expect(stored[101], 'A-second');
  });

  test('same-name newer success is not undone by an older failure', () async {
    final reply = Completer<ChangeProxyResult>();
    var calls = 0;
    when(() => core.changeProxy(any())).thenAnswer((_) => ++calls == 1
        ? reply.future
        : Future.value(const ChangeProxyResult(changed: false)));
    final first = action().changeProxy(groupName: 'G', proxyName: 'A-new');
    await action().changeProxy(groupName: 'G', proxyName: 'A-new');
    reply.completeError(StateError('older same-name request'));
    await first;
    expect((await persisted())[101], 'A-new');
  });

  test('profile A-B-A does not revive the old request', () async {
    final reply = Completer<ChangeProxyResult>();
    when(() => core.changeProxy(any())).thenAnswer((_) => reply.future);
    final pending = action().changeProxy(groupName: 'G', proxyName: 'A-new');
    container.read(currentProfileIdProvider.notifier).value = 202;
    expect(container.read(currentProfileProvider)?.id, 202);
    container.read(currentProfileIdProvider.notifier).value = 101;
    expect(container.read(currentProfileProvider)?.id, 101);
    reply.completeError(StateError('old A epoch'));
    await pending;
    expect((await persisted())[101], 'A-new');
  });

  test('disposed owner ignores a late failure', () async {
    final reply = Completer<ChangeProxyResult>();
    when(() => core.changeProxy(any())).thenAnswer((_) => reply.future);
    final pending = action().changeProxy(groupName: 'G', proxyName: 'A-new');
    await persisted();
    container.dispose();
    disposed = true;
    reply.completeError(StateError('disposed owner'));
    await pending;
    final rows = await database.profilesDao.query().get();
    expect(rows.firstWhere((p) => p.id == 101).selectedMap['G'], 'A-new');
  });

  test('a queued request is not dispatched after profile change', () async {
    action().changeProxyDebounce('G', 'A-new');
    container.read(currentProfileIdProvider.notifier).value = 202;
    expect(container.read(currentProfileProvider)?.id, 202);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    verifyNever(() => core.changeProxy(any()));
    expect((await persisted())[202], 'B-own');
  });

  test('rapid debounced choices retain the original rollback target', () async {
    final called = Completer<void>();
    when(() => core.changeProxy(any())).thenAnswer((_) async {
      called.complete();
      return const ChangeProxyResult(message: 'controlled rejection');
    });
    action().changeProxyDebounce('G', 'A-first');
    action().changeProxyDebounce('G', 'A-second');
    await called.future;
    await Future<void>.delayed(Duration.zero);
    expect((await persisted())[101], 'A-old');
    verify(() => core.changeProxy(any())).called(1);
    debouncer.cancel(FunctionTag.updateGroups);
  });

  test('superseded in-flight failures do not restore an unaccepted choice', () async {
    final firstReply = Completer<ChangeProxyResult>();
    var calls = 0;
    when(() => core.changeProxy(any())).thenAnswer((_) => ++calls == 1
        ? firstReply.future
        : Future.value(const ChangeProxyResult(message: 'newer rejected')));
    final first = action().changeProxy(groupName: 'G', proxyName: 'A-first');
    await action().changeProxy(groupName: 'G', proxyName: 'A-second');
    firstReply.completeError(StateError('older rejected'));
    await first;
    expect((await persisted())[101], 'A-old');
  });

  test('late success does not reset connections belonging to another profile', () async {
    final reply = Completer<ChangeProxyResult>();
    when(() => core.changeProxy(any())).thenAnswer((_) => reply.future);
    final pending = action().changeProxy(groupName: 'G', proxyName: 'A-new');
    container.read(currentProfileIdProvider.notifier).value = 202;
    expect(container.read(currentProfileProvider)?.id, 202);
    reply.complete(const ChangeProxyResult(changed: true));
    await pending;
    verifyNever(core.closeConnections);
    verifyNever(core.resetConnections);
    expect((await persisted())[202], 'B-own');
  });
}
