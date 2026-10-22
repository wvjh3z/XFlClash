// Standalone native test executable. Never invokes a compiler or real rustup.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final control = File(
    '${File(Platform.resolvedExecutable).parent.path}/control.json',
  );
  final config = jsonDecode(control.readAsStringSync()) as Map;
  final pin = config['pin'] as String;
  if (args.length < 3 || args[0] != 'run' || args[1] != pin) {
    stderr.writeln('unfixed toolchain rejected');
    exit(91);
  }
  if (args[2] == 'rustc') {
    stdout.writeln(
      'rustc ${config['wrongVersion'] == true ? '0.0.0' : pin} (fixture)',
    );
  } else if (args.contains('--version')) {
    stdout.writeln('cargo $pin (fixture)');
  } else {
    if (config['failBuild'] == true) exit(23);
    final target = args[args.indexOf('--target') + 1];
    final directory = Directory('target/$target/release')
      ..createSync(recursive: true);
    final suffix = target.contains('windows') ? '.exe' : '';
    File('${directory.path}/helper$suffix').writeAsStringSync('binary:$target');
    if (suffix.isNotEmpty && config['omitPdb'] != true) {
      File('${directory.path}/helper.pdb').writeAsStringSync('symbols:$target');
    }
    File(
      '${control.parent.path}/builds.log',
    ).writeAsStringSync('$target\n', mode: FileMode.append);
  }
}
