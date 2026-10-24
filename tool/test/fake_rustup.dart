// Standalone native test executable. Never invokes a compiler or real rustup.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final control = File(
    '${File(Platform.resolvedExecutable).parent.path}/control.json',
  );
  final config = jsonDecode(control.readAsStringSync()) as Map;
  if (args.isNotEmpty && args.first == 'env') {
    stdout.writeln(
      jsonEncode({'GOVERSION': 'go${config['go_pin']}', 'GOWORK': 'off'}),
    );
    return;
  }
  if (args.isNotEmpty && args.first == 'list') {
    stdout.writeln(File('cmd/core/main.go').absolute.path);
    return;
  }
  if (args.isNotEmpty && args.first == 'build') {
    File('${control.parent.path}/go-arguments.json').writeAsStringSync(
      jsonEncode(args),
    );
    final output = File(args[args.indexOf('-o') + 1]);
    output.parent.createSync(recursive: true);
    if (config['failBuild'] == true) {
      output.writeAsStringSync('partial staging file');
      exit(23);
    }
    output.writeAsStringSync(
      'runtime:${Platform.environment['GOOS']}:${Platform.environment['GOARCH']}|PRIVATE',
    );
    return;
  }
  if (args.contains('--extract-go')) {
    final binary = File(args[args.indexOf('--extract-go') + 1]);
    final output = args[args.indexOf('--output') + 1];
    final dwarf = File('$output/Contents/Resources/DWARF/FlClashCore');
    dwarf.parent.createSync(recursive: true);
    dwarf.writeAsBytesSync(binary.readAsBytesSync());
    File('$output/Contents/Info.plist').writeAsStringSync('controlled fixture');
    return;
  }
  if (args.isNotEmpty &&
      (args.first == '--strip-debug' || args.first == 'strip')) {
    final binary = File(args.last);
    binary.writeAsStringSync(binary.readAsStringSync().split('|').first);
    return;
  }
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
