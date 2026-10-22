// Drives production helpers using the prepared client/plugin package graph.
// No application dependency is added for this cross-package test harness.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';
import 'package:setup_hooks/src/build_cache.dart';
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/core_builder.dart';
import 'package:setup_hooks/src/options.dart' as setup;
import 'package:setup_hooks/src/rust_builder.dart';
import 'package:setup_hooks/src/target.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_rust/src/crate_info_validator.dart';
import 'package:native_toolchain_rust/src/toml_parsing.dart';
import '../../plugins/rust_api/hook/xboard_symbols.dart';

Future<void> main(List<String> args) async {
  final root = Directory(args[1]);
  if (args.first == 'manifest') {
    final logger = Logger('manifest-regression');
    final factory = TomlDocumentWrapperFactory(logger);
    final value =
        CrateInfoValidator(
          toolchainTomlParser: ToolchainTomlParser(logger, factory),
          cargoManifestParser: CargoManifestParser(logger, factory),
        ).fetchAndValidateCrateInfo(
          manifestPath: '${root.path}/manifest/Cargo.toml',
          toolchainTomlPath: '${root.path}/manifest/rust-toolchain.toml',
          targetTriple: args[2],
        );
    stdout.writeln(jsonEncode({'toolchain': value.toolchainChannel}));
    return;
  }
  if (args.first == 'go') {
    void put(String name, String data) {
      final file = File('${root.path}/$name');
      if (!file.existsSync()) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(data);
      }
    }

    put('core/go.mod', 'module fixture\ngo 1.27\n');
    put('core/cmd/core/main.go', 'package main\nfunc main() {}\n');
    put('pubspec.yaml', 'name: fixture\n');
    final package = Directory('${root.path}/plugins/setup')
      ..createSync(recursive: true);
    final os = {
      'windows': OS.windows,
      'linux': OS.linux,
      'macos': OS.macOS,
    }[args[2]]!;
    final arch = args[3] == 'arm64' ? Architecture.arm64 : Architecture.x64;
    final input = BuildInputBuilder()
      ..setupShared(
        packageRoot: package.uri,
        packageName: 'setup',
        outputDirectoryShared: root.uri.resolve('hook/'),
        outputFile: root.uri.resolve('hook/output.json'),
      )
      ..setupBuildInput()
      ..config.setupBuild(linkingEnabled: false);
    CodeAssetExtension(
      targetOS: os,
      targetArchitecture: arch,
      linkModePreference: LinkModePreference.dynamic,
      macOS: os == OS.macOS ? MacOSCodeConfig(targetVersion: 12) : null,
    ).setupBuildInput(input);
    BuildReport? report;
    final output = BuildOutputBuilder();
    await CoreBuilder(
      hostArchitecture: arch,
      build: (request) async {
        report = await buildPlatform(request);
        return report!;
      },
    ).run(input: input.build(), output: output);
    File('${root.path}/go-result.json').writeAsStringSync(
      jsonEncode({
        'rebuilt': report!.rebuilt,
        'outputs': report!.outputs,
        'dependencies': output
            .build()
            .dependencies
            .map((uri) => uri.toString())
            .toList(),
      }),
    );
    return;
  }
  if (args.first == 'helper') {
    final target = Target.resolve(platform: args[2], goarch: args[3]);
    final result = await RustBuilder(
      rootDir: root.path,
      config: setup.BuildConfig.load(rootDir: root.path),
      cache: BuildCache(rootDir: root.path),
      notice: BuildNotice(),
    ).build(target, 'controlled-core-hash');
    stdout.writeln(
      jsonEncode({
        'rebuilt': result.rebuilt,
        'outputs': result.outputs,
        'dependencies': result.inputs
            .map((path) => File(path).uri.toString())
            .toList(),
      }),
    );
    return;
  }
  final os = {
    'android': OS.android,
    'linux': OS.linux,
    'windows': OS.windows,
    'macos': OS.macOS,
  }[args[2]]!;
  final arch = args[3] == 'arm64' ? Architecture.arm64 : Architecture.x64;
  final package = Directory('${root.path}/plugins/rust_api')
    ..createSync(recursive: true);
  final source = Directory('${root.path}/source/${os.name}/${arch.name}')
    ..createSync(recursive: true);
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: package.uri,
      packageName: 'rust_api',
      outputDirectoryShared: source.uri,
      outputFile: source.uri.resolve('output.json'),
    )
    ..setupBuildInput()
    ..config.setupBuild(linkingEnabled: false);
  CodeAssetExtension(
    targetOS: os,
    targetArchitecture: arch,
    linkModePreference: LinkModePreference.dynamic,
    android: os == OS.android ? AndroidCodeConfig(targetNdkApi: 24) : null,
    macOS: os == OS.macOS ? MacOSCodeConfig(targetVersion: 12) : null,
  ).setupBuildInput(builder);
  final name = os == OS.windows
      ? 'rust_api.dll'
      : os == OS.macOS
      ? 'librust_api.dylib'
      : 'librust_api.so';
  final binary = File('${source.path}/$name');
  if (!binary.existsSync()) {
    binary.writeAsStringSync('binary ${os.name} ${arch.name}');
  }
  if (os == OS.windows) {
    final pdb = File('${source.path}/rust_api.pdb');
    if (!pdb.existsSync()) pdb.writeAsStringSync('PDB ${arch.name}');
  }
  if (os == OS.macOS) {
    final dwarf = File('${binary.path}.dSYM/Contents/Resources/DWARF/$name');
    if (!dwarf.existsSync()) {
      dwarf.parent.createSync(recursive: true);
      dwarf.writeAsStringSync('DWARF ${arch.name}');
    }
  }
  final output = BuildOutputBuilder();
  output.assets.code.add(
    CodeAsset(
      package: 'rust_api',
      name: 'src/rust/frb_generated.io.dart',
      file: binary.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
  await captureXboardNativeSymbols(builder.build(), output);
  stdout.writeln(
    jsonEncode({
      'dependencies': output
          .build()
          .dependencies
          .map((uri) => uri.toString())
          .toList(),
    }),
  );
}
