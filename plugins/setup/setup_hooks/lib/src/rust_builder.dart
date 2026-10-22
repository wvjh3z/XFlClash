import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'error.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('rust_builder');

class RustBuilder {
  RustBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    this.harnessInputs = const [],
  });

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;

  String get _helperPath => p.join(rootDir, config.helperDir);
  String get _outputPath => p.join(rootDir, config.outputDir);

  String get _toolchain {
    final pins = jsonDecode(
      File(p.join(rootDir, 'tool', 'native_toolchain.json')).readAsStringSync(),
    );
    final version = pins is Map ? pins['rust'] : null;
    if (version is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw BuildException('A fixed Rust version is required for the helper');
    }
    return version;
  }

  Future<BuildExecution> build(Target target, String coreSha256) async {
    final triple = target.rustTriple;
    final toolchain = _toolchain;
    final args = [
      'build',
      '--target',
      triple,
      if (target.goos == 'windows') ...['--features', 'windows-service'],
      '--release',
    ];
    final env = {
      'CORE_SHA256': coreSha256,
      'CORE_NAME': '${config.coreName}${target.executableExtension}',
    };

    final srcPath = p.join(
      _helperPath,
      'target',
      triple,
      'release',
      'helper${target.executableExtension}',
    );
    final destDir = p.join(_outputPath, target.platformDir);
    final destPath = p.join(
      destDir,
      '${config.helperName}${target.executableExtension}',
    );
    final privateOutputs = [
      srcPath,
      if (target.goos == 'windows') p.join(p.dirname(srcPath), 'helper.pdb'),
    ];
    final result = await cache.run(
      key: '${target.platformDir}-${target.goarch}-helper-release',
      fingerprint: () => _calculateFingerprint(
        target: target,
        coreSha256: coreSha256,
        args: args,
        toolchain: toolchain,
      ),
      primaryOutput: destPath,
      notice: notice,
      verifyOutputContent: true,
      build: () async {
        _log.info('Building Rust helper: $target');

        // Cargo can retain a primary binary after a companion was removed or
        // damaged. Removing only these target-specific outputs forces it to
        // relink; keep the previous distributed copy until the build succeeds.
        for (final path in privateOutputs) {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        }

        await runCommandStream(
          'rustup',
          ['run', toolchain, 'cargo', ...args],
          workingDirectory: _helperPath,
          environment: env,
        );

        for (final path in privateOutputs) {
          final file = File(path);
          if (!file.existsSync() || file.lengthSync() == 0) {
            throw BuildException(
              'Missing helper output or debug companion: $path',
            );
          }
        }

        ensureDir(destDir);
        copyFile(srcPath, destPath);

        _log.info('Built: $destPath');
        return [destPath, ...privateOutputs];
      },
    );
    // The outer Flutter hook cache must also observe private file contents;
    // directory-name dependencies alone miss in-place symbol replacement.
    return BuildExecution(
      primaryOutput: result.primaryOutput,
      rebuilt: result.rebuilt,
      inputs: {...result.inputs, ...result.outputs}.toList(),
      outputs: result.outputs,
    );
  }

  Future<Fingerprint> _calculateFingerprint({
    required Target target,
    required String coreSha256,
    required List<String> args,
    required String toolchain,
  }) async {
    final builder = FingerprintBuilder(rootDir: rootDir)
      ..addValue('cache_schema', BuildCache.schemaVersion)
      ..addValue('kind', 'helper')
      ..addValue('target', {'goos': target.goos, 'goarch': target.goarch})
      ..addValue('arguments', args)
      ..addValue('rust_toolchain', toolchain)
      ..addValue('core_sha256', coreSha256)
      ..addValue('environment', _rustEnvironment())
      ..addValue('config', config.toFingerprintMap());

    final cargoVersion = runCommand('rustup', [
      'run',
      toolchain,
      'cargo',
      '--version',
    ], workingDirectory: _helperPath);
    builder.addValue('cargo_version', (cargoVersion.stdout as String).trim());
    final rustVersion = runCommand('rustup', [
      'run',
      toolchain,
      'rustc',
      '-Vv',
    ], workingDirectory: _helperPath);
    if (!(rustVersion.stdout as String).startsWith('rustc $toolchain ')) {
      throw BuildException(
        'The helper Rust compiler differs from the fixed version',
      );
    }
    builder.addValue('rustc_version', (rustVersion.stdout as String).trim());

    final inputs =
        collectFiles(
            _helperPath,
            excludedDirectories: const {'target', '.git', '.idea'},
          )
          ..addAll(harnessInputs)
          ..add(p.join(rootDir, 'tool', 'native_toolchain.json'));
    builder.addFiles(inputs);
    return builder.finishWithInputs();
  }

  Map<String, String> _rustEnvironment() {
    const exactKeys = {
      'CARGO_BUILD_TARGET',
      'CARGO_ENCODED_RUSTFLAGS',
      'RUSTFLAGS',
      'RUSTUP_TOOLCHAIN',
      'RUSTC_WRAPPER',
      'RUSTC_WORKSPACE_WRAPPER',
    };
    final values = <String, String>{};
    final entries = Platform.environment.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries) {
      if (exactKeys.contains(entry.key) ||
          entry.key.startsWith('CARGO_PROFILE_') ||
          entry.key.startsWith('CARGO_TARGET_')) {
        values[entry.key] = entry.value;
      }
    }
    return values;
  }
}
