import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/lock.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/dart_executable.dart';

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('xb-lock-中文-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  Future<({Process process, StreamIterator<String> lines})> start(
    String brand,
  ) async {
    final process = await Process.start(dartExecutable(), [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      'test/xboard/storage/fixtures/instance_lock_process.dart',
      '${temp.path}/FlClash.lock',
      '${temp.path}/initialization',
      brand,
    ]);
    final errors = process.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(() async {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 15));
      await lines.cancel();
      expect(await errors, isEmpty);
    });
    return (process: process, lines: lines);
  }

  Future<String> next(StreamIterator<String> lines) async {
    expect(await lines.moveNext().timeout(const Duration(seconds: 15)), isTrue);
    return lines.current;
  }

  for (final brands in [
    ['brand_a', 'brand_a'],
    ['brand_b', 'brand_b'],
    ['brand_a', 'brand_b'],
  ]) {
    test(
      '${brands.join('/')} only owner initializes; repeated acquire retains lock; release permits restart',
      () async {
        final first = await start(brands[0]);
        expect(await next(first.lines), 'ready');
        final second = await start(brands[1]);
        expect(await next(second.lines), 'occupied');
        expect(await second.process.exitCode, 0);
        expect(
          await File('${temp.path}/initialization').readAsString(),
          brands[0],
        );
        // A failed contender must not delete/recreate the lock inode.
        final third = await start(brands[1]);
        expect(await next(third.lines), 'occupied');
        first.process.stdin.writeln('release');
        expect(await next(first.lines), 'released');
        expect(await first.process.exitCode, 0);
        final restarted = await start(brands[1]);
        expect(await next(restarted.lines), 'ready');
        restarted.process.stdin.writeln('release');
        expect(await next(restarted.lines), 'released');
        expect(
          await File('${temp.path}/initialization').readAsString(),
          brands.join(),
        );
      },
    );
  }

  test(
    'missing directory propagates I/O error and permits a later attempt',
    () async {
      final file = File('${temp.path}/missing/lock');
      final lock = SingleInstanceLock(lockFilePath: () async => file.path);
      await expectLater(lock.acquire(), throwsA(isA<FileSystemException>()));
      await file.parent.create();
      expect(await lock.acquire(), isTrue);
      await lock.release();
      await lock.release();
    },
  );

  test('path provider failure is not treated as another instance', () async {
    final lock = SingleInstanceLock(
      lockFilePath: () async => throw StateError('path'),
    );
    await expectLater(lock.acquire(), throwsStateError);
  });

  test(
    'production startup gate precedes all data initialization and exempts WebView children',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      final helper = main.indexOf('runWebViewTitleBarWidget(args)');
      final gate = main.indexOf('!await singleInstanceLock.acquire()');
      expect(helper, greaterThan(0));
      expect(gate, greaterThan(helper));
      for (final initialization in [
        'await XboardModule.initializeMonitoringEarly',
        'await RustLib.init()',
        'await globalState.init(version)',
      ]) {
        expect(main.indexOf(initialization), greaterThan(gate));
      }
      expect(
        main,
        contains('system.isDesktop && !await singleInstanceLock.acquire()'),
      );
      expect(main.substring(helper, gate), contains('return;'));
      expect(
        File('lib/common/window.dart').readAsStringSync(),
        isNot(contains('singleInstanceLock.acquire')),
      );
      expect(
        File('lib/database/database.dart').readAsStringSync(),
        contains('return openProfileDatabase(databaseFile);'),
      );
    },
  );
}
