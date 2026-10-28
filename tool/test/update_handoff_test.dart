// Standalone CLI fixture uses the distributor package graph in cold CI, which
// deliberately has no fl_clash package entry. Relative imports keep this test
// limited to pure Dart helpers and never activate application native hooks.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../../lib/xboard/services/xb_update_lease.dart';
import '../../lib/xboard/services/xb_appimage_install.dart';
import '../../lib/xboard/services/xb_appimage_restart.dart';

class Ticket extends XbAppImageRestartTicket {
  Ticket(super.directory, {this.failCommit = false, this.failCancel = false});
  final bool failCommit;
  final bool failCancel;
  bool committed = false;
  bool cancelled = false;
  @override
  Future<void> commit() async {
    if (failCommit) throw StateError('commit failed');
    committed = true;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (failCancel) throw StateError('cancel failed');
  }
}

void main() {
  for (final brand in ['omofly', 'daishu']) {
    test(
      '$brand real install exit restores and restarts previous image',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'xb-install-$brand-',
        );
        addTearDown(() => root.delete(recursive: true));
        final target = File('${root.path}/$brand.AppImage');
        final marker = File('${root.path}/old-started');
        await target.writeAsString(
          '#!/bin/sh\nprintf restored > "${marker.path}"\n',
        );
        expect((await Process.run('chmod', ['+x', target.path])).exitCode, 0);
        final oldBytes = await target.readAsBytes();
        final download = File('${root.path}/download');
        await download.writeAsBytes([127, 69, 76, 70, 0, 1, 2]);
        final helper = File(
          'lib/xboard/services/xb_appimage_install.dart',
        ).absolute.uri;
        final source = File('${root.path}/parent.dart');
        await source.writeAsString("""import 'dart:io';
import '$helper';
Future<void> main(List<String> args) async {
  await xbInstallAppImage(downloadedPath: args[0], appImagePath: args[1],
    requestExit: () async { exit(0); });
}
""");
        final parent = await Process.start(Platform.resolvedExecutable, [
          source.path,
          download.path,
          target.path,
        ]);
        addTearDown(() {
          parent.kill();
        });
        final output = parent.stdout.drain<void>();
        final errors = parent.stderr.transform(utf8.decoder).join();
        expect(
          await parent.exitCode.timeout(const Duration(seconds: 15)),
          0,
          reason: await errors,
        );
        await output;
        final deadline = Stopwatch()..start();
        while (!await marker.exists()) {
          if (deadline.elapsed > const Duration(seconds: 10)) {
            fail('old image was not restarted after actual parent exit');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(await target.readAsBytes(), oldBytes);
        final backups = await root
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('/previous.AppImage'))
            .toList();
        expect(backups, hasLength(1));
        expect(await File(backups.single.path).readAsBytes(), oldBytes);
      },
      skip: !Platform.isLinux,
    );
  }

  group('AppImage exec failure recovery', () {
    for (final brand in ['omofly', 'daishu']) {
      for (final scenario in [
        'recover',
        'restore-fails',
        'success',
        'app-exits-127',
        'old-script-negative',
      ]) {
        test('$brand $scenario', () async {
          final root = await Directory.systemTemp.createTemp(
            'xb-$brand-中文 space-',
          );
          addTearDown(() => root.delete(recursive: true));
          final target = File('${root.path}/$brand AppImage');
          final backup = File('${root.path}/previous.AppImage');
          final marker = File('${root.path}/old-started');
          await backup.writeAsString(
            '#!/bin/sh\nprintf old > "${marker.path}"\n',
          );
          expect((await Process.run('chmod', ['+x', backup.path])).exitCode, 0);
          final oldBytes = await backup.readAsBytes();
          if (scenario == 'success' || scenario == 'app-exits-127') {
            await target.writeAsString(
              '#!/bin/sh\nexit ${scenario == 'success' ? 0 : 127}\n',
            );
          } else {
            await target.writeAsBytes([127, 69, 76, 70, 0, 1, 2, 3]);
          }
          expect((await Process.run('chmod', ['+x', target.path])).exitCode, 0);
          final newBytes = await target.readAsBytes();
          final control = await Directory('${root.path}/control').create();
          final ready = File('${control.path}/ready');
          final parent = await Process.start('/bin/sh', ['-c', 'exit 0']);
          await parent.exitCode;
          final script = scenario == 'old-script-negative'
              ? xbAppImageRestartScript.replaceFirst(
                  'trap recover_launch 0',
                  ':',
                )
              : xbAppImageRestartScript;
          final child = await Process.start('/bin/sh', [
            '-c',
            script,
            'xb-recovery-test',
            '${parent.pid}',
            '0',
            target.path,
            ready.path,
            backup.path,
          ]);
          addTearDown(() {
            child.kill();
          });
          final output = child.stdout.drain<void>();
          final errors = child.stderr.drain<void>();
          final deadline = Stopwatch()..start();
          while (!await ready.exists()) {
            if (deadline.elapsed > const Duration(seconds: 10)) {
              fail('waiter not ready');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          if (scenario == 'restore-fails') {
            await target.delete();
            await Directory(target.path).create();
            await File('${target.path}/retain').writeAsString('do not remove');
          }
          await File('${control.path}/commit').writeAsString('commit');
          final code = await child.exitCode.timeout(
            const Duration(seconds: 10),
          );
          await Future.wait([output, errors]);
          expect(await backup.readAsBytes(), oldBytes);
          if (scenario == 'recover') {
            expect(code, 0);
            expect(await target.readAsBytes(), oldBytes);
            expect(await marker.readAsString(), 'old');
          } else if (scenario == 'restore-fails') {
            expect(code, isNot(0));
            expect(
              await File('${target.path}/retain').readAsString(),
              'do not remove',
            );
            expect(await marker.exists(), isFalse);
            expect(
              await File('${backup.path}.restart.log').readAsString(),
              contains('restore_failed'),
            );
          } else {
            expect(
              code,
              scenario == 'success'
                  ? 0
                  : scenario == 'app-exits-127'
                  ? 127
                  : isNot(0),
            );
            expect(await target.readAsBytes(), newBytes);
            expect(await marker.exists(), isFalse);
          }
        });
      }
    }
  }, skip: !Platform.isLinux);

  test(
    'lease stays held through installer lifetime and stale release is harmless',
    () async {
      final gate = XbUpdateGate();
      final first = gate.acquire()!;
      expect(gate.acquire(), isNull);
      final installerExit = Completer<void>();
      final completion = installerExit.future.then((_) => first.release());
      expect(gate.acquire(), isNull);
      installerExit.complete();
      await completion;
      final second = gate.acquire()!;
      first.release();
      expect(gate.acquire(), isNull);
      second.release();
      expect(gate.acquire(), isNotNull);
    },
  );

  test(
    'real installer child is drained and holds ownership until exit',
    () async {
      final root = await Directory.systemTemp.createTemp('installer-child-');
      addTearDown(() => root.delete(recursive: true));
      final script = File('${root.path}/installer.dart');
      await script.writeAsString(
        "import 'dart:io'; void main() { stdout.write('x' * 200000); stderr.write('y' * 200000); stdin.readByteSync(); exit(7); }",
      );
      final gate = XbUpdateGate();
      final child = await Process.start(Platform.resolvedExecutable, [
        script.path,
      ]);
      addTearDown(() {
        child.kill();
      });
      final waiter = xbWaitForInstaller(child, gate.acquire()!);
      expect(gate.acquire(), isNull);
      child.stdin.add([1]);
      await child.stdin.close();
      await waiter.timeout(const Duration(seconds: 20));
      expect(gate.acquire(), isNotNull);
    },
  );

  group('real AppImage waiter supervision', () {
    late Directory root;
    late File target;
    late File download;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('waiter-real-');
      target = await File('${root.path}/image').writeAsString('old');
      download = await File('${root.path}/download').writeAsString('new');
    });
    tearDown(() => root.delete(recursive: true));

    test(
      'ready file left by a dead process is rejected before replacing',
      () async {
        Process? child;
        await expectLater(
          xbInstallAppImage(
            downloadedPath: download.path,
            appImagePath: target.path,
            requestExit: () async {
              fail('must not exit');
            },
            prepareRestart: (path) => xbPrepareAppImageRestart(
              path,
              startProcess: (args, env) async {
                final changed = List<String>.from(args);
                changed[1] = r'printf "ready\n" > "$4"; exit 23';
                child = await Process.start(
                  '/bin/sh',
                  changed,
                  environment: env,
                  includeParentEnvironment: false,
                );
                await child!.exitCode;
                return child!;
              },
            ),
          ),
          throwsStateError,
        );
        expect(await child!.exitCode, 23);
        expect(await target.readAsString(), 'old');
      },
    );

    test(
      'death after ready is caught at commit and restores the old file',
      () async {
        Process? child;
        XbAppImageRestartTicket? ticket;
        await expectLater(
          xbInstallAppImage(
            downloadedPath: download.path,
            appImagePath: target.path,
            requestExit: () async {
              fail('must not exit');
            },
            prepareRestart: (path) async {
              ticket = await xbPrepareAppImageRestart(
                path,
                startProcess: (args, env) async {
                  child = await Process.start(
                    '/bin/sh',
                    args,
                    environment: env,
                    includeParentEnvironment: false,
                  );
                  return child!;
                },
              );
              child!.kill(ProcessSignal.sigkill);
              await child!.exitCode;
              // The old implementation accepted this leftover marker.
              expect(
                await File('${ticket!.directory.path}/ready').exists(),
                isTrue,
              );
              return ticket!;
            },
          ),
          throwsStateError,
        );
        expect(await target.readAsString(), 'old');
        expect(await ticket!.directory.exists(), isFalse);
      },
    );

    test(
      'death receiving commit is rejected without a positive acknowledgement',
      () async {
        Process? child;
        await expectLater(
          xbInstallAppImage(
            downloadedPath: download.path,
            appImagePath: target.path,
            requestExit: () async {
              fail('must not exit');
            },
            prepareRestart: (path) => xbPrepareAppImageRestart(
              path,
              startProcess: (args, env) async {
                final changed = List<String>.from(args);
                changed[1] = xbAppImageRestartScript.replaceFirst(
                  xbAppImageRestartScript
                      .split('\n')
                      .firstWhere((line) => line.contains('/accepted')),
                  'exit 24',
                );
                expect(changed[1], isNot(xbAppImageRestartScript));
                child = await Process.start(
                  '/bin/sh',
                  changed,
                  environment: env,
                  includeParentEnvironment: false,
                );
                return child!;
              },
            ),
          ),
          throwsStateError,
        );
        expect(await child!.exitCode, 24);
        expect(await target.readAsString(), 'old');
      },
    );

    test(
      'missing commit acknowledgement times out and cancels the real waiter',
      () async {
        Process? child;
        await expectLater(
          xbInstallAppImage(
            downloadedPath: download.path,
            appImagePath: target.path,
            requestExit: () async {
              fail('must not exit');
            },
            prepareRestart: (path) => xbPrepareAppImageRestart(
              path,
              startProcess: (args, env) async {
                final changed = List<String>.from(args);
                changed[1] = xbAppImageRestartScript.replaceFirst(
                  xbAppImageRestartScript
                      .split('\n')
                      .firstWhere((line) => line.contains('/accepted')),
                  r'while [ ! -f "$control/cancel" ]; do "$sleep_command" 1; done; exit 125',
                );
                child = await Process.start(
                  '/bin/sh',
                  changed,
                  environment: env,
                  includeParentEnvironment: false,
                );
                return child!;
              },
            ),
          ),
          throwsStateError,
        );
        expect(await child!.exitCode, 125);
        expect(await target.readAsString(), 'old');
      },
    );

    test(
      'real Dart parent exit leaves the acknowledged waiter able to launch',
      () async {
        final marker = File('${root.path}/launched');
        final executable = File('${root.path}/新版 AppImage');
        await executable.writeAsString(
          '#!/bin/sh\nprintf launched > "${marker.path}"\n',
        );
        expect(
          (await Process.run('chmod', ['+x', executable.path])).exitCode,
          0,
        );
        final helper = File(
          'lib/xboard/services/xb_appimage_restart.dart',
        ).absolute.uri;
        final source = File('${root.path}/parent.dart');
        await source.writeAsString("""import 'dart:io';
import '$helper';
Future<void> main(List<String> args) async {
  final ticket=await xbPrepareAppImageRestart(args[0]);
  await ticket.commit();
  stdout.writeln('accepted');
  await stdin.first;
  exit(0);
}
""");
        final parent = await Process.start(Platform.resolvedExecutable, [
          source.path,
          executable.path,
        ]);
        final ready = Completer<void>();
        final stdoutSubscription = parent.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line == 'accepted' && !ready.isCompleted) ready.complete();
            });
        final errors = parent.stderr.transform(utf8.decoder).join();
        try {
          await ready.future.timeout(const Duration(seconds: 15));
          expect(await marker.exists(), isFalse);
          parent.stdin.add([1]);
          await parent.stdin.close();
          expect(
            await parent.exitCode.timeout(const Duration(seconds: 10)),
            0,
            reason: await errors,
          );
          final deadline = Stopwatch()..start();
          while (!await marker.exists()) {
            if (deadline.elapsed > const Duration(seconds: 10)) {
              fail('replacement did not launch');
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          expect(await marker.readAsString(), 'launched');
        } finally {
          parent.kill();
          await stdoutSubscription.cancel();
        }
      },
    );

    test(
      'production waiter acknowledges commit and cancellation reaps it',
      () async {
        Process? child;
        final ticket = await xbPrepareAppImageRestart(
          target.path,
          startProcess: (args, env) async {
            child = await Process.start(
              '/bin/sh',
              args,
              environment: env,
              includeParentEnvironment: false,
            );
            return child!;
          },
        );
        await ticket.commit();
        expect(
          await File('${ticket.directory.path}/accepted').readAsString(),
          'accepted\n',
        );
        await ticket.cancel();
        expect(await child!.exitCode, 125);
        expect(await ticket.directory.exists(), isFalse);
      },
    );
  }, testOn: 'linux');

  group('AppImage file transaction', () {
    late Directory root;
    late File target;
    late File download;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('image-中文-');
      target = await File(
        '${root.path}/袋鼠 app.AppImage',
      ).writeAsString('old image');
      download = await File('${root.path}/download').writeAsString('new image');
    });
    tearDown(() async => root.delete(recursive: true));
    for (final failure in ['prepare', 'commit', 'exit', 'cancel']) {
      test('$failure failure restores original and disarms waiter', () async {
        final ticket = Ticket(
          root,
          failCommit: failure == 'commit',
          failCancel: failure == 'cancel',
        );
        var exitCalled = false;
        await expectLater(
          xbInstallAppImage(
            downloadedPath: download.path,
            appImagePath: target.path,
            prepareRestart: (_) async {
              expect(await target.readAsString(), 'old image');
              if (failure == 'prepare') throw StateError('cannot start helper');
              return ticket;
            },
            requestExit: () async {
              exitCalled = true;
              expect(ticket.committed, isTrue);
              expect(await target.readAsString(), 'new image');
              throw StateError('exit failed');
            },
          ),
          throwsStateError,
        );
        expect(await target.readAsString(), 'old image');
        expect(ticket.cancelled, failure != 'prepare');
        expect(exitCalled, failure == 'exit' || failure == 'cancel');
        expect(root.listSync().whereType<Directory>(), isEmpty);
      });
    }
    test(
      'success requests exit independently of any widget and preserves recovery',
      () async {
        final ticket = Ticket(root);
        var exits = 0;
        await xbInstallAppImage(
          downloadedPath: download.path,
          appImagePath: target.path,
          prepareRestart: (_) async => ticket,
          requestExit: () async {
            exits++;
          },
        );
        expect(exits, 1);
        expect(ticket.committed, isTrue);
        expect(ticket.cancelled, isFalse);
        expect(await target.readAsString(), 'new image');
        final backups = root
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('previous.AppImage'));
        expect(backups, hasLength(1));
        expect(await backups.single.readAsString(), 'old image');
      },
    );
    test('failed restore retains the recovery image', () async {
      await expectLater(
        xbInstallAppImage(
          downloadedPath: download.path,
          appImagePath: target.path,
          prepareRestart: (_) async => Ticket(root),
          requestExit: () async {
            await target.delete();
            await Directory(target.path).create();
            throw StateError('exit failed');
          },
        ),
        throwsStateError,
      );
      final backups = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('previous.AppImage'));
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), 'old image');
    });
  }, testOn: 'linux');
}
