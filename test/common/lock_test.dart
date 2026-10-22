import 'dart:io';

import 'package:fl_clash/common/lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';

void main() {
  late Directory directory;
  late SingleInstanceLock lock;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('flclash-lock-');
    lock = SingleInstanceLock(
      lockFilePath: () async => join(directory.path, 'FlClash.lock'),
    );
  });

  tearDown(() async {
    await lock.release();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'acquiring creates the persistent inode used by other processes',
    () async {
      final file = File(join(directory.path, 'FlClash.lock'));
      expect(file.existsSync(), isFalse);
      expect(await lock.acquire(), isTrue);
      expect(await lock.acquire(), isTrue);
      expect(file.existsSync(), isTrue);
      await lock.release();
      expect(file.existsSync(), isTrue);
    },
  );

  test('an unusable path is a startup failure, not another instance', () async {
    final missing = SingleInstanceLock(
      lockFilePath: () async => join(directory.path, 'missing', 'FlClash.lock'),
    );
    await expectLater(missing.acquire(), throwsA(isA<FileSystemException>()));
  });

  test('a directory at the lock path reports an I/O error', () async {
    Directory(join(directory.path, 'FlClash.lock')).createSync();
    await expectLater(lock.acquire(), throwsA(isA<FileSystemException>()));
  });

  test(
    'path-resolution failure is not mistaken for an occupied lock',
    () async {
      final unavailable = SingleInstanceLock(
        lockFilePath: () async =>
            throw const FileSystemException('no data directory'),
      );
      await expectLater(
        unavailable.acquire(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
