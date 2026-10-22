import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/xboard_symbols.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('native-symbols-中文-'));
  tearDown(() => root.deleteSync(recursive: true));

  (BuildInput, BuildOutputBuilder, File) fixture(OS os) {
    final package = Directory('${root.path}/plugins/rust_api')
      ..createSync(recursive: true);
    final shared = Directory('${root.path}/short temp output')..createSync();
    final builder = BuildInputBuilder()
      ..setupShared(
        packageRoot: package.uri,
        packageName: 'rust_api',
        outputDirectoryShared: shared.uri,
        outputFile: shared.uri.resolve('output.json'),
      )
      ..setupBuildInput()
      ..config.setupBuild(linkingEnabled: false);
    CodeAssetExtension(
      targetOS: os,
      targetArchitecture: Architecture.x64,
      linkModePreference: LinkModePreference.dynamic,
      android: os == OS.android ? AndroidCodeConfig(targetNdkApi: 24) : null,
      macOS: os == OS.macOS ? MacOSCodeConfig(targetVersion: 12) : null,
    ).setupBuildInput(builder);
    final binary = File(
      '${shared.path}/${os == OS.windows
          ? 'rust_api.dll'
          : os == OS.macOS
          ? 'librust_api.dylib'
          : 'librust_api.so'}',
    )..writeAsStringSync('unique-runtime-bytes');
    final output = BuildOutputBuilder();
    output.assets.code.add(
      CodeAsset(
        package: 'rust_api',
        name: 'src/rust/frb_generated.io.dart',
        file: binary.uri,
        linkMode: DynamicLoadingBundled(),
      ),
    );
    return (builder.build(), output, binary);
  }

  for (final os in [OS.android, OS.linux, OS.windows, OS.macOS]) {
    test(
      '${os.name}: actual output and companion captured outside app assets',
      () async {
        final (input, output, binary) = fixture(os);
        if (os == OS.windows)
          File.fromUri(
            binary.uri.resolve('rust_api.pdb'),
          ).writeAsStringSync('pdb');
        if (os == OS.macOS) {
          final dwarf = File(
            '${binary.path}.dSYM/Contents/Resources/DWARF/librust_api.dylib',
          );
          dwarf.parent.createSync(recursive: true);
          dwarf.writeAsStringSync('dwarf');
        }
        await captureXboardNativeSymbols(input, output);
        final capture = Directory(
          '${root.path}/build/sentry-hook-inputs/${os.name}/x64',
        );
        final record =
            jsonDecode(File('${capture.path}/manifest.json').readAsStringSync())
                as Map;
        expect(record['platform'], os.name);
        expect(
          File('${capture.path}/${record['binary']}').readAsBytesSync(),
          binary.readAsBytesSync(),
        );
        expect(
          output.build().assets.code.length,
          1,
          reason: 'private symbols are not bundled assets',
        );
        await captureXboardNativeSymbols(input, output);
        expect(
          record,
          jsonDecode(File('${capture.path}/manifest.json').readAsStringSync()),
        );
      },
    );
  }
  test('missing Windows PDB fails, without a success record', () async {
    final (input, output, _) = fixture(OS.windows);
    await expectLater(
      captureXboardNativeSymbols(input, output),
      throwsStateError,
    );
    expect(
      File(
        '${root.path}/build/sentry-hook-inputs/windows/x64/manifest.json',
      ).existsSync(),
      false,
    );
  });
  test('missing macOS dSYM fails before publishing a record', () async {
    final (input, output, _) = fixture(OS.macOS);
    await expectLater(
      captureXboardNativeSymbols(input, output),
      throwsStateError,
    );
    expect(
      File(
        '${root.path}/build/sentry-hook-inputs/macos/x64/manifest.json',
      ).existsSync(),
      false,
    );
  });
  test('ambiguous native assets fail', () async {
    final (input, output, binary) = fixture(OS.linux);
    output.assets.code.add(
      CodeAsset(
        package: 'rust_api',
        name: 'extra.dart',
        file: binary.uri,
        linkMode: DynamicLoadingBundled(),
      ),
    );
    await expectLater(
      captureXboardNativeSymbols(input, output),
      throwsStateError,
    );
  });
}
