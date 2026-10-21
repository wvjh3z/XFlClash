import 'dart:convert';
import 'dart:io';

String dartExecutable() {
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final flutter = (config['packages'] as List).cast<Map>().singleWhere(
    (entry) => entry['name'] == 'flutter',
  );
  final sdk = Directory.fromUri(
    configFile.uri.resolve(flutter['rootUri'] as String),
  ).uri;
  return sdk
      .resolve(
        '../../bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
      )
      .toFilePath();
}
