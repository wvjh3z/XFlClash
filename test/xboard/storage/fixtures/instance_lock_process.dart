import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/lock.dart';

Future<void> main(List<String> args) async {
  final lock = SingleInstanceLock(lockFilePath: () async => args[0]);
  try {
    // Same object, concurrent/repeated acquisition must keep the original handle.
    final acquired = await Future.wait([lock.acquire(), lock.acquire()]);
    if (!acquired.every((value) => value)) {
      stdout.writeln('occupied');
      return;
    }
    // Represents initialization after the gate; a loser must never write here.
    await File(args[1]).writeAsString(args[2], mode: FileMode.append);
    stdout.writeln('ready');
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    await lock.release();
    stdout.writeln('released');
  } catch (error) {
    stderr.writeln(error.runtimeType);
    exitCode = 2;
  }
}
