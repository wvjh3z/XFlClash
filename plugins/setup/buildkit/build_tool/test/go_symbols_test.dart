import 'package:build_tool/src/go_builder.dart';
import 'package:build_tool/src/target.dart';
import 'package:test/test.dart';

void main() {
  test('Android and Linux linker flags retain DWARF and ELF build IDs', () {
    for (final target in [Target.androidArm64, Target.linuxAmd64]) {
      expect(
        goLdflagsFor(target, '-w -s -X main.version=test'),
        '-w -s -X main.version=test -s=false -w=false -B gobuildid',
      );
    }
  });

  test('macOS retains DWARF without ELF-specific linker options', () {
    expect(goLdflagsFor(Target.macosArm64, '-w -s'),
        '-w -s -s=false -w=false');
  });

  test('Windows linker options remain unchanged', () {
    expect(goLdflagsFor(Target.windowsAmd64, '-w -s'), '-w -s');
  });
}
