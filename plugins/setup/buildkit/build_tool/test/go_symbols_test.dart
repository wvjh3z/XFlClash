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

  test('Windows and macOS linker options remain unchanged', () {
    for (final target in [Target.windowsAmd64, Target.macosArm64]) {
      expect(goLdflagsFor(target, '-w -s'), '-w -s');
    }
  });
}
