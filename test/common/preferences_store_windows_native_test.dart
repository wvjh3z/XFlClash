import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _quoted(String value) => "'${value.replaceAll("'", "''")}'";

List<String> _powershell(String script) {
  final units = script.codeUnits;
  final bytes = <int>[
    for (final unit in units) ...[unit & 255, unit >> 8],
  ];
  return [
    '-NoProfile', '-NonInteractive', '-EncodedCommand', base64Encode(bytes),
  ];
}

Future<void> _run(String script) async {
  final result = await Process.run('powershell.exe', _powershell(
    "\$ErrorActionPreference='Stop'; $script",
  ));
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final brand in ['brand_a', 'brand_b']) {
    for (final fault in ['held_handle', 'read_only', 'deny_create']) {
      test('$brand $fault rejects candidate and recovers without leakage',
          () async {
        final directory = await Directory.systemTemp.createTemp('prefs-win-$brand-');
        final path = p.join(directory.path, 'preferences.json');
        final file = File(path);
        final savedAcl = p.join(directory.path, 'original.sddl');
        final ready = File(p.join(directory.path, 'holder-ready'));
        final release = File(p.join(directory.path, 'holder-release'));
        Process? holder;
        Future<String>? stderr;
        var faultInstalled = false;
        try {
          await file.writeAsString(jsonEncode({
            'flutter.session': 'committed-$brand',
            'other': 'untouched',
          }), flush: true);
          final store = AtomicFilePreferencesStore(Future.value(path));
          expect((await store.getAll())['flutter.session'], 'committed-$brand');
          switch (fault) {
            case 'held_handle':
              holder = await Process.start('powershell.exe', _powershell('''
\$ErrorActionPreference='Stop'
\$h=[IO.File]::Open(${_quoted(path)},[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
try {
  [IO.File]::WriteAllText(${_quoted(ready.path)},'ready')
  \$watch=[Diagnostics.Stopwatch]::StartNew()
  while(-not [IO.File]::Exists(${_quoted(release.path)})) {
    if(\$watch.Elapsed.TotalSeconds -gt 30) { throw 'Holder release timeout' }
    Start-Sleep -Milliseconds 25
  }
} finally { \$h.Dispose() }
'''));
              unawaited(holder.stdout.drain<void>());
              stderr = holder.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
              final deadline = Stopwatch()..start();
              while (!await ready.exists()) {
                if (deadline.elapsed > const Duration(seconds: 20)) {
                  fail('Handle holder did not signal readiness');
                }
                await Future<void>.delayed(const Duration(milliseconds: 25));
              }
            case 'read_only':
              await _run('[IO.File]::SetAttributes(${_quoted(path)},[IO.FileAttributes]::ReadOnly)');
            case 'deny_create':
              await _run('''
\$acl=Get-Acl -LiteralPath ${_quoted(directory.path)}
[IO.File]::WriteAllText(${_quoted(savedAcl)},\$acl.Sddl)
\$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
\$rule=New-Object Security.AccessControl.FileSystemAccessRule(\$sid,'CreateFiles','Deny')
\$acl.AddAccessRule(\$rule)
Set-Acl -LiteralPath ${_quoted(directory.path)} -AclObject \$acl
''');
          }
          faultInstalled = true;
          if (fault == 'deny_create') {
            // Prove the OS denies creation before exercising the store.
            await expectLater(File(p.join(directory.path, 'denied-probe'))
                .writeAsString('denied'), throwsA(isA<FileSystemException>()));
          }
          expect(await store.setValue('String', 'flutter.session', 'rejected-$brand'), isFalse);
          expect((await store.getAll())['flutter.session'], 'committed-$brand');
          expect((jsonDecode(await file.readAsString()) as Map)['flutter.session'], 'committed-$brand');

          if (holder != null) {
            await release.writeAsString('release');
            expect(await holder.exitCode.timeout(const Duration(seconds: 20)), 0,
                reason: await stderr);
            holder = null;
          } else if (fault == 'read_only') {
            await _run('[IO.File]::SetAttributes(${_quoted(path)},[IO.FileAttributes]::Normal)');
          } else {
            await _run('''
\$acl=Get-Acl -LiteralPath ${_quoted(directory.path)}
\$acl.SetSecurityDescriptorSddlForm([IO.File]::ReadAllText(${_quoted(savedAcl)}))
Set-Acl -LiteralPath ${_quoted(directory.path)} -AclObject \$acl
''');
          }
          faultInstalled = false;
          expect(await store.setValue('bool', 'flutter.later', true), isTrue);
          final reopened = AtomicFilePreferencesStore(Future.value(path));
          expect(await reopened.getAll(), {
            'flutter.session': 'committed-$brand', 'flutter.later': true,
          });
          expect((jsonDecode(await file.readAsString()) as Map)['other'], 'untouched');
          expect(await File('$path.$pid.tmp').exists(), isFalse);
        } finally {
          if (holder != null) {
            holder.kill();
            await holder.exitCode;
          }
          if (faultInstalled && fault == 'read_only') {
            await _run('[IO.File]::SetAttributes(${_quoted(path)},[IO.FileAttributes]::Normal)');
          }
          if (faultInstalled && fault == 'deny_create') {
            await _run('''
\$acl=Get-Acl -LiteralPath ${_quoted(directory.path)}
\$acl.SetSecurityDescriptorSddlForm([IO.File]::ReadAllText(${_quoted(savedAcl)}))
Set-Acl -LiteralPath ${_quoted(directory.path)} -AclObject \$acl
''');
          }
          await directory.delete(recursive: true);
        }
      }, skip: !Platform.isWindows);
    }
  }
}
