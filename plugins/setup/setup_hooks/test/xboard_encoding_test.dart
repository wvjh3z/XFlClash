import 'dart:io';
import 'package:logging/logging.dart';
import 'package:setup_hooks/src/error.dart';
import 'package:setup_hooks/src/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('构建 日志-'));
  tearDown(() => root.deleteSync(recursive: true));
  String script(String body) {
    final file = File('${root.path}/中文 fixture.dart');
    file.writeAsStringSync(
      "import 'dart:io';\nimport 'dart:convert';\nvoid main() { $body }\n",
    );
    return file.path;
  }

  test('UTF-8 protocol paths survive native default code page', () {
    final path = script(
      "stdout.write(jsonEncode({'path':'中文 路径'})); stderr.add([255]);",
    );
    final result = runCommand(Platform.resolvedExecutable, [path]);
    expect(result.stdout, contains('中文 路径'));
    expect(result.stderr, contains('�'));
  });
  test('protocol corruption fails instead of replacing path bytes', () {
    final path = script('stdout.add([255]);');
    expect(
      () => runCommand(Platform.resolvedExecutable, [path]),
      throwsFormatException,
    );
  });
  test(
    'streams drain fragmented UTF-8 and malformed diagnostics before exit',
    () async {
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      final messages = <String>[];
      final listener = Logger.root.onRecord.listen(
        (record) => messages.add(record.message),
      );
      addTearDown(() async {
        await listener.cancel();
        Logger.root.level = previous;
      });
      final path = script(
        "final bytes=utf8.encode('中文尾部'); for(final byte in bytes) {stdout.add([byte]);} stderr.add([255]);",
      );
      await runCommandStream(Platform.resolvedExecutable, [path]);
      expect(messages, contains('中文尾部'));
      expect(messages, contains('�'));
      final failed = script("stderr.add([255]); exitCode=23;");
      await expectLater(
        runCommandStream(Platform.resolvedExecutable, [failed]),
        throwsA(isA<CommandFailedException>()),
      );
    },
  );
}
