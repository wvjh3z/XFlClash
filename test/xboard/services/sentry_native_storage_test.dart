import 'dart:io';

import 'package:fl_clash/xboard/services/sentry_native_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('other platforms do not resolve or create a Windows native database', () async {
    var called = false;
    expect(await prepareXbSentryNativeDatabase(
      isWindows: false,
      cacheDirectory: () async {
        called = true;
        throw StateError('must not resolve');
      },
    ), isNull);
    expect(called, isFalse);
  });

  for (final brand in ['brand_a', 'brand_b']) {
    test('$brand uses its cache root and preserves existing native reports', () async {
      final root = await Directory.systemTemp.createTemp('sentry-cache-');
      addTearDown(() => root.delete(recursive: true));
      final cache = Directory(p.join(root.path, brand, 'cache'));
      final database = await prepareXbSentryNativeDatabase(
        isWindows: true, cacheDirectory: () async => cache,
      );
      expect(database, p.join(cache.path, 'sentry-native'));
      final report = File(p.join(database!, 'pending-report'));
      await report.writeAsString('preserved');
      expect(await prepareXbSentryNativeDatabase(
        isWindows: true, cacheDirectory: () async => cache,
      ), database);
      expect(await report.readAsString(), 'preserved');
      expect(await Directory(p.join(root.path, 'other-brand')).exists(), isFalse);
    });
  }

  test('unusable cache root fails instead of falling back to the install directory', () async {
    final root = await Directory.systemTemp.createTemp('sentry-cache-blocked-');
    addTearDown(() => root.delete(recursive: true));
    final blocker = File(p.join(root.path, 'cache'));
    await blocker.writeAsString('keep');
    await expectLater(prepareXbSentryNativeDatabase(
      isWindows: true,
      cacheDirectory: () async => Directory(blocker.path),
    ), throwsA(isA<FileSystemException>()));
    expect(await blocker.readAsString(), 'keep');
  });
}
