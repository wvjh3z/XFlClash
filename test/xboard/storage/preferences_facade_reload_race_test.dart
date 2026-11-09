import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/common/preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

class _DelayedReplyStore extends AtomicFilePreferencesStore {
  _DelayedReplyStore(super.path);
  Completer<void>? release;
  Completer<void>? captured;

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    final snapshot = await super.getAllWithParameters(parameters);
    final gate = release;
    if (gate != null) {
      release = null;
      captured!.complete();
      await gate.future;
    }
    return snapshot;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mutation in ['different-key', 'remove', 'clear', 'failed-write']) {
    test('facade reload cannot overwrite $mutation and later reload remains usable', () async {
      final previous = SharedPreferencesStorePlatform.instance;
      final directory = await Directory.systemTemp.createTemp('facade-mutations-');
      final path = '${directory.path}/preferences.json';
      final store = _DelayedReplyStore(Future.value(path));
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = store;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('existing', 'before');
        final release = Completer<void>();
        store.release = release;
        store.captured = Completer<void>();
        final reload = prefs.reload();
        await store.captured!.future;
        if (mutation == 'different-key') {
          expect(await prefs.setString('other', 'after'), isTrue);
        } else if (mutation == 'remove') {
          expect(await prefs.remove('existing'), isTrue);
        } else if (mutation == 'clear') {
          expect(await prefs.clear(), isTrue);
        } else {
          final blocker = Directory('$path.$pid.tmp');
          await blocker.create();
          await File('${blocker.path}/occupied').writeAsString('fixture');
          expect(await prefs.setString('existing', 'rejected'), isFalse);
          await blocker.delete(recursive: true);
        }
        release.complete();
        await reload;
        if (mutation == 'different-key') {
          expect(prefs.getString('other'), 'after');
          expect(prefs.getString('existing'), 'before');
        } else if (mutation == 'remove' || mutation == 'clear') {
          expect(prefs.getString('existing'), isNull);
        }
        await prefs.reload();
        if (mutation == 'failed-write') expect(prefs.getString('existing'), 'before');
        expect(await prefs.setString('later', 'usable'), isTrue);
        await prefs.reload();
        expect(prefs.getString('later'), 'usable');
      } finally {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = previous;
        await directory.delete(recursive: true);
      }
    });
  }

  test('later reload wins when platform replies complete out of order', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final directory = await Directory.systemTemp.createTemp('facade-two-reads-');
    final store = _DelayedReplyStore(Future.value('${directory.path}/prefs.json'));
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('setting', 'before');
      final firstRelease = Completer<void>();
      store.release = firstRelease;
      store.captured = Completer<void>();
      final first = prefs.reload();
      await store.captured!.future;
      await store.setValue('String', 'flutter.setting', 'native-new');
      final secondRelease = Completer<void>();
      store.release = secondRelease;
      store.captured = Completer<void>();
      final second = prefs.reload();
      await store.captured!.future;
      secondRelease.complete();
      await second;
      expect(prefs.getString('setting'), 'native-new');
      firstRelease.complete();
      await first;
      expect(prefs.getString('setting'), 'native-new');
    } finally {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previous;
      await directory.delete(recursive: true);
    }
  });

  test('reload refreshes unchanged keys while preserving an overlapping other-key write', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final directory = await Directory.systemTemp.createTemp('facade-key-merge-');
    final store = _DelayedReplyStore(Future.value('${directory.path}/prefs.json'));
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('authority', 'cached-old');
      await store.setValue('String', 'flutter.authority', 'committed-new');
      final release = Completer<void>();
      store.release = release;
      store.captured = Completer<void>();
      final reload = prefs.reload();
      await store.captured!.future;
      await prefs.setString('unrelated', 'local-new');
      release.complete();
      await reload;
      expect(prefs.getString('authority'), 'committed-new');
      expect(prefs.getString('unrelated'), 'local-new');
    } finally {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previous;
      await directory.delete(recursive: true);
    }
  });

  for (final brand in ['brand_a', 'brand_b']) {
    for (final overlap in [false, true]) {
      test('G05 $brand facade reload ${overlap ? "overlaps committed write" : "ordered control"}', () async {
        final previous = SharedPreferencesStorePlatform.instance;
        final directory = await Directory.systemTemp.createTemp('facade-reload-');
        final path = '${directory.path}/preferences.json';
        final store = _DelayedReplyStore(Future.value(path));
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = store;
        try {
          final prefs = await SharedPreferences.getInstance();
          final key = '${brand}_synthetic_setting';
          expect(await prefs.setString(key, 'before'), isTrue);
          if (overlap) {
            final release = Completer<void>();
            store.release = release;
            store.captured = Completer<void>();
            final reload = prefs.reload();
            await store.captured!.future.timeout(const Duration(seconds: 3));
            expect(await prefs.setString(key, 'committed'), isTrue);
            expect(prefs.getString(key), 'committed');
            release.complete();
            await reload;
          } else {
            await prefs.reload();
            expect(await prefs.setString(key, 'committed'), isTrue);
          }
          final disk = jsonDecode(await File(path).readAsString()) as Map;
          expect(disk['flutter.$key'], 'committed');
          expect((await store.getAll())['flutter.$key'], 'committed');
          expect(prefs.getString(key), 'committed',
            reason: 'An older reload reply must not overwrite a successful newer facade write');
        } finally {
          SharedPreferences.resetStatic();
          SharedPreferencesStorePlatform.instance = previous;
          await directory.delete(recursive: true);
        }
      });
    }
  }
}
