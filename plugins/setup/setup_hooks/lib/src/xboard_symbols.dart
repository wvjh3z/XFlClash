import 'dart:io';

import 'package:path/path.dart' as p;

import 'target.dart';
import 'util.dart';

/// Split the exact build before CoreBuilder hashes it for the helper/manifest.
/// Cached outputs include companions: deleting one must invalidate the cache.
Future<List<String>> prepareGoSymbols({
  required String rootDir,
  required String binary,
  required String output,
  required Target target,
}) async {
  if (target.goos == 'windows') return const [];
  if (target.goos == 'linux') {
    final full = '$output.unstripped';
    // Keep the full private input for strict code/build-ID comparison; only a
    // debug-only companion is sent to Sentry by the existing postbuild tool.
    final stagedFull = '$binary.unstripped';
    await File(binary).copy(stagedFull);
    await runCommandStream('strip', [
      '--strip-debug',
      binary,
    ], workingDirectory: rootDir);
    replaceFile(stagedFull, full);
    return [full];
  }
  if (target.goos == 'darwin') {
    final stagedDsym = '$binary.dSYM';
    await runCommandStream('python3', [
      p.join(rootDir, 'tool', 'prepare_sentry_macos_symbols.py'),
      '--extract-go',
      binary,
      '--output',
      stagedDsym,
    ], workingDirectory: rootDir);
    await runCommandStream('xcrun', [
      'strip',
      '-S',
      binary,
    ], workingDirectory: rootDir);
    final destination = Directory('$output.dSYM');
    if (destination.existsSync()) destination.deleteSync(recursive: true);
    Directory(stagedDsym).renameSync(destination.path);
    return [
      for (final file
          in destination.listSync(recursive: true).whereType<File>())
        file.path,
    ];
  }
  return const [];
}
