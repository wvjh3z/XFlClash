import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:fl_clash/xboard/services/xb_update_source_download.dart';
import 'package:test/test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final ResponseBody Function(RequestOptions, int) reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(options);
    return reply(options, requests.length);
  }
  @override
  void close({bool force = false}) {}
}

const _url = 'https://update.invalid/package';
ResponseBody _body(List<int> bytes, int status, int length, {
  String tag = '"version-a"', String? range, String? encoding,
}) => ResponseBody.fromBytes(bytes, status, headers: {
  'etag': [tag], 'content-length': ['$length'],
  if (range != null) 'content-range': [range],
  if (encoding != null) 'content-encoding': [encoding],
});

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('xb-verified-range-');
    file = File('${directory.path}/partial');
  });
  tearDown(() => directory.delete(recursive: true));

  test('only the exact remaining bytes of the same representation are appended', () async {
    final adapter = _Adapter((options, n) {
      expect(options.uri.toString(), _url);
      expect(options.headers['accept-encoding'], 'identity');
      if (n == 1) return _body([1, 2], 200, 5);
      expect(options.headers['range'], 'bytes=2-');
      expect(options.headers['if-range'], '"version-a"');
      return _body([3, 4, 5], 206, 3, range: 'bytes 2-4/5');
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final progress = <(int, int)>[];
    await xbDownloadUpdateSource(dio, _url, file,
        onProgress: (n, total) => progress.add((n, total)), canRecover: () => true);
    expect(progress.last, (5, 5));
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5]);
    expect(adapter.requests.length, 2);
    dio.close();
  });

  for (final kind in ['changed-etag', 'weak', 'offset', 'total', 'length', 'encoded', 'ignored', '416', 'no-strong-tag']) {
    test('unsafe range $kind never contributes bytes to a new artifact', () async {
      final adapter = _Adapter((o, n) {
        if (n == 1) return _body([88, 99], 200, 5, tag: kind == 'no-strong-tag' ? 'W/"weak"' : '"version-a"');
        if (o.headers['range'] == null || kind == 'ignored') return _body([9, 8, 7, 6], 200, 4, tag: '"version-b"');
        if (kind == '416') return _body([], 416, 0);
        return _body([111, 112, 113], 206, kind == 'length' ? 4 : 3,
            tag: kind == 'changed-etag' ? '"version-b"' : kind == 'weak' ? 'W/"version-a"' : '"version-a"',
            range: kind == 'offset' ? 'bytes 1-3/5' : kind == 'total' ? 'bytes 2-4/6' : 'bytes 2-4/5',
            encoding: kind == 'encoded' ? 'gzip' : null);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      await xbDownloadUpdateSource(dio, _url, file, onProgress: (_, _) {}, canRecover: () => true);
      expect(await file.readAsBytes(), [9, 8, 7, 6]);
      expect(adapter.requests.length, kind == 'ignored' || kind == 'no-strong-tag' ? 2 : 3);
      dio.close();
    });
  }

  for (final tail in [[3, 4], [3, 4, 5, 6]]) {
    test('validated headers do not excuse incorrect final file size ${tail.length}', () async {
      final adapter = _Adapter((_, n) => n == 1
          ? _body([1, 2], 200, 5)
          : _body(tail, 206, 3, range: 'bytes 2-4/5'));
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(xbDownloadUpdateSource(dio, _url, file,
        canRecover: () => true, onProgress: (_, _) {},
      ), throwsA(isA<DioException>()));
      expect(adapter.requests.length, 2);
      dio.close();
    });
  }

  for (final cancelled in [false, true]) {
    test('no recovery request after backgrounding or cancellation cancel=$cancelled', () async {
      final token = CancelToken();
      final adapter = _Adapter((_, _) => _body([1, 2], 200, 5));
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(xbDownloadUpdateSource(dio, _url, file,
        cancelToken: token, canRecover: () => cancelled,
        onProgress: (_, _) { if (cancelled) token.cancel('switched'); },
      ), throwsA(isA<DioException>()));
      expect(adapter.requests.length, 1);
      dio.close();
    });
  }

  test('a different mirror always truncates a partial from the previous mirror', () async {
    final adapter = _Adapter((o, _) => o.uri.host == 'update.invalid'
        ? _body([88, 99], 200, 5) : _body([9, 8, 7], 200, 3));
    final dio = Dio()..httpClientAdapter = adapter;
    await expectLater(xbDownloadUpdateSource(dio, _url, file,
        onProgress: (_, _) {}, canRecover: () => false), throwsA(isA<DioException>()));
    await xbDownloadUpdateSource(dio, 'https://mirror.invalid/package', file,
        onProgress: (_, _) {}, canRecover: () => true);
    expect(adapter.requests.last.headers['range'], isNull);
    expect(await file.readAsBytes(), [9, 8, 7]);
    dio.close();
  });
}
