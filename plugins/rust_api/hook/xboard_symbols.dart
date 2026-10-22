/// Record the actual Native Assets output, including Windows short-temp paths.
/// Companions are private build inputs, never additional app assets.
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

Future<void> captureXboardNativeSymbols(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final platform = code.targetOS.name;
  if (!const {'android', 'linux', 'windows', 'macos'}.contains(platform)) {
    return;
  }
  final assets = output
      .build()
      .assets
      .code
      .where((asset) => asset.file != null)
      .toList();
  if (assets.length != 1) {
    throw StateError('Rust symbol capture requires exactly one native asset');
  }
  final binary = File.fromUri(assets.single.file!);
  if (!await binary.exists() || await binary.length() == 0) {
    throw StateError('Native Assets Rust output is missing');
  }
  final name = binary.uri.pathSegments.last;
  final root = input.packageRoot.resolve('../../');
  final destination = Directory.fromUri(
    root.resolve(
      'build/sentry-hook-inputs/$platform/${code.targetArchitecture.name}/',
    ),
  );
  await destination.parent.create(recursive: true);
  final staged = await destination.parent.createTemp('.rust-symbols-');
  try {
    await binary.copy('${staged.path}/$name');
    final companions = <String>[];
    if (platform == 'windows') {
      final pdb = File.fromUri(binary.uri.resolve('rust_api.pdb'));
      if (!await pdb.exists()) {
        throw StateError('Native Assets Rust PDB is missing');
      }
      await pdb.copy('${staged.path}/rust_api.pdb');
      companions.add('rust_api.pdb');
    }
    if (platform == 'macos') {
      final dsym = Directory('${binary.path}.dSYM');
      if (!await dsym.exists()) {
        throw StateError('Native Assets Rust dSYM is missing');
      }
      final copied = Directory('${staged.path}/$name.dSYM');
      await copied.create();
      await for (final entry in dsym.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = entry.path.substring(dsym.path.length + 1);
        final path = '${copied.path}/$relative';
        if (entry is Directory) {
          await Directory(path).create(recursive: true);
        } else if (entry is File) {
          await File(path).parent.create(recursive: true);
          await entry.copy(path);
        } else {
          throw StateError('Unexpected link inside Rust debug companion');
        }
      }
      companions.add('$name.dSYM');
    }
    await File('${staged.path}/manifest.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'platform': platform,
        'architecture': code.targetArchitecture.name,
        'binary': name,
        'companions': companions,
      }),
    );
    // Per-target hook builds are serialized by flutter_rust_bridge_hooks.
    // Invalidate stale output before promotion; failure must not look current.
    if (await destination.exists()) await destination.delete(recursive: true);
    await staged.rename(destination.path);
    output.dependencies.add(destination.uri);
    // A directory dependency hashes only immediate names. Register files too,
    // including nested dSYM contents, so deletion or damage reruns the hook.
    await for (final entry in destination.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) output.dependencies.add(entry.uri);
    }
  } finally {
    if (await staged.exists()) await staged.delete(recursive: true);
  }
}
