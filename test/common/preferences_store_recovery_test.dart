import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

// Real facade and files: a rejected platform write must not enter a later save.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late String path;
  late SharedPreferencesStorePlatform previousStore;

  AtomicFilePreferencesStore openStore() =>
      AtomicFilePreferencesStore(Future.value(path));

  Future<Map<String, dynamic>> readDisk() async =>
      jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

  Future<Directory> blockWrites() async {
    // The production writer uses this sibling. A non-empty directory makes
    // writing it fail even under root, without changing any user permissions.
    final blocker = Directory('$path.$pid.tmp');
    await blocker.create();
    await File(join(blocker.path, 'fixture')).writeAsString('keep');
    return blocker;
  }

  Future<SharedPreferences> reopen({required bool replaceStore}) async {
    SharedPreferences.resetStatic();
    if (replaceStore) SharedPreferencesStorePlatform.instance = openStore();
    return SharedPreferences.getInstance();
  }

  setUp(() async {
    previousStore = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    directory = await Directory.systemTemp.createTemp('prefs-recovery-');
    path = join(directory.path, 'shared_preferences.json');
    await File(path).writeAsString(
      jsonEncode({'flutter.config': 'old', 'other': 'untouched'}),
      flush: true,
    );
    SharedPreferencesStorePlatform.instance = openStore();
  });

  tearDown(() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previousStore;
    await directory.delete(recursive: true);
  });

  for (final remove in [false, true]) {
    final operation = remove ? 'remove' : 'set';
    final String? changed = remove ? null : 'rejected';

    Future<bool> mutate(SharedPreferences preferences) => remove
        ? preferences.remove('config')
        : preferences.setString('config', 'rejected');

    test('$operation failure: reload restores the committed snapshot',
        () async {
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('config'), 'old');
      await blockWrites();

      expect(await mutate(preferences), isFalse);
      expect((await readDisk())['flutter.config'], 'old');
      expect(preferences.getString('config'), changed);

      await preferences.reload();
      expect(preferences.getString('config'), 'old');
      expect((await readDisk())['flutter.config'], 'old');

      final sameStore = await reopen(replaceStore: false);
      expect(sameStore.getString('config'), 'old');
      final newStore = await reopen(replaceStore: true);
      expect(newStore.getString('config'), 'old');
      expect((await readDisk())['other'], 'untouched');
    });

    test('$operation failure is not persisted by a later unrelated write',
        () async {
      final preferences = await SharedPreferences.getInstance();
      final blocker = await blockWrites();
      expect(await mutate(preferences), isFalse);
      await preferences.reload();
      expect((await readDisk())['flutter.config'], 'old');

      await blocker.delete(recursive: true);
      expect((await readDisk())['flutter.config'], 'old');
      expect(await preferences.setBool('later', true), isTrue);

      final disk = await readDisk();
      expect(disk['flutter.config'], 'old');
      expect(disk.containsKey('flutter.config'), isTrue);
      expect(disk['flutter.later'], isTrue);
      expect(disk['other'], 'untouched');
      final reopened = await reopen(replaceStore: true);
      expect(reopened.getString('config'), 'old');
      expect(reopened.getBool('later'), isTrue);
    });
  }

  test('an explicit retry after recovery persists the latest requested value',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final blocker = await blockWrites();
    expect(await preferences.setString('config', 'rejected'), isFalse);
    expect((await readDisk())['flutter.config'], 'old');

    await blocker.delete(recursive: true);
    expect(await preferences.setString('config', 'accepted'), isTrue);
    await preferences.reload();
    expect(preferences.getString('config'), 'accepted');
    expect((await readDisk())['flutter.config'], 'accepted');
    final reopened = await reopen(replaceStore: true);
    expect(reopened.getString('config'), 'accepted');
    expect(directory.listSync().map((entry) => basename(entry.path)),
        ['shared_preferences.json']);
  });

  test('rejected clear preserves committed keys and unrelated prefixes', () async {
    final preferences = await SharedPreferences.getInstance();
    final blocker = await blockWrites();
    expect(await preferences.clear(), isFalse);
    expect(preferences.containsKey('config'), isFalse);
    await preferences.reload();
    expect(preferences.getString('config'), 'old');
    await blocker.delete(recursive: true);
    expect(await preferences.setBool('later', true), isTrue);
    expect(await readDisk(), {
      'flutter.config': 'old',
      'flutter.later': true,
      'other': 'untouched',
    });
  });

  test('facade without reload cannot leak its rejected value into another key',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final blocker = await blockWrites();
    expect(await preferences.setString('config', 'rejected'), isFalse);
    expect(preferences.getString('config'), 'rejected');
    await blocker.delete(recursive: true);
    expect(await preferences.setBool('later', true), isTrue);
    expect((await readDisk())['flutter.config'], 'old');
    await preferences.reload();
    expect(preferences.getString('config'), 'old');
  });

  test('queued failures leave a later recovered write based on committed data',
      () async {
    final store = openStore();
    final blocker = await blockWrites();
    final results = await Future.wait([
      store.setValue('String', 'flutter.config', 'rejected'),
      store.remove('other'),
      store.setValue('Bool', 'flutter.rejected', true),
    ]);
    expect(results, everyElement(isFalse));
    await blocker.delete(recursive: true);
    expect(await store.setValue('Int', 'flutter.accepted', 1), isTrue);
    expect(await readDisk(), {
      'flutter.config': 'old',
      'other': 'untouched',
      'flutter.accepted': 1,
    });
  });

  test('a later failure does not roll back an earlier successful write', () async {
    final store = openStore();
    expect(await store.setValue('String', 'flutter.config', 'accepted'), isTrue);
    final blocker = await blockWrites();
    expect(await store.setValue('String', 'flutter.config', 'rejected'), isFalse);
    expect((await store.getAll())['flutter.config'], 'accepted');
    await blocker.delete(recursive: true);
    expect(await store.setValue('Bool', 'flutter.later', true), isTrue);
    expect((await readDisk())['flutter.config'], 'accepted');
  });

  test('queued same-key writes and reads observe operation order', () async {
    final ready = Completer<String>();
    final store = AtomicFilePreferencesStore(ready.future);
    final first = store.setValue('String', 'flutter.config', 'first');
    final middle = store.getAll();
    final last = store.setValue('String', 'flutter.config', 'last');
    ready.complete(path);
    expect(await first, isTrue);
    expect((await middle)['flutter.config'], 'first');
    expect(await last, isTrue);
    expect((await readDisk())['flutter.config'], 'last');
  });

  test('list input is captured before queueing and read snapshots are detached',
      () async {
    final ready = Completer<String>();
    final store = AtomicFilePreferencesStore(ready.future);
    final values = ['original'];
    final writing = store.setValue('StringList', 'flutter.list', values);
    values.add('caller-change');
    ready.complete(path);
    expect(await writing, isTrue);
    final read = await store.getAll();
    expect(read['flutter.list'], ['original']);
    (read['flutter.list'] as List).add('reader-change');
    expect(await store.setValue('Bool', 'flutter.later', true), isTrue);
    expect((await readDisk())['flutter.list'], ['original']);
  });

  test('initial load errors do not poison the operation queue', () async {
    await File(path).writeAsString('{broken');
    final store = openStore();
    await expectLater(store.setValue('String', 'flutter.a', 'lost'),
        throwsFormatException);
    await expectLater(store.getAll(), throwsFormatException);
    await File(path).writeAsString(jsonEncode({'flutter.config': 'repaired'}));
    expect(await store.setValue('Bool', 'flutter.later', true), isTrue);
    expect(await readDisk(), {
      'flutter.config': 'repaired',
      'flutter.later': true,
    });
  });
}
