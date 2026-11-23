import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/xboard/services/payment_channel_icon_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SVG channel class paints retain their source colors and unsupported CSS is untouched', () {
    Uint8List icon(String css) => Uint8List.fromList(utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg"><style>$css</style><path class="base"/><g class="mark"><path/></g></svg>',
    ));
    final result = utf8.decode(normalizePaymentSvgPaint(icon('.base{fill:#2DC100;} .mark{fill:#FFFFFF;}')));
    expect(result, contains('fill="#2DC100"'));
    expect(result, contains('fill="#FFFFFF"'));
    final untouched = icon('.base:hover{fill:#333;}');
    expect(normalizePaymentSvgPaint(untouched), same(untouched));
  });
  test('retrieves SVG and raster artwork anonymously, including safe redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = Uri.http('127.0.0.1:${server.port}');
    final headers = <(String?, List<Cookie>)>[];
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="23" height="23"/>';
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN0sAAAAASUVORK5CYII=',
    );
    server.listen((request) async {
      headers.add((
        request.headers.value(HttpHeaders.authorizationHeader),
        request.cookies,
      ));
      final response = request.response;
      switch (request.uri.path) {
        case '/redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '/payment');
          response.cookies.add(Cookie('redirect-cookie', 'must-not-be-sent'));
        case '/payment':
          response.headers.contentType = ContentType.binary;
          response.write(svg);
        case '/card':
          response.headers.contentType = ContentType('image', 'png');
          response.add(png);
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final artwork = await loadPaymentChannelIcon(base.resolve('/redirect'));
    final card = await loadPaymentChannelIcon(base.resolve('/card'));
    expect(artwork?.isSvg, isTrue);
    expect(utf8.decode(artwork!.bytes), svg);
    expect(card?.isSvg, isFalse);
    expect(card?.bytes, png);
    expect(headers, hasLength(3));
    for (final (token, cookies) in headers) {
      expect(token, isNull);
      expect(cookies, isEmpty);
    }
  });

  test('rejects unsupported and oversized responses and unsafe redirect targets', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = Uri.http('127.0.0.1:${server.port}');
    final visited = <String>[];
    server.listen((request) async {
      visited.add(request.uri.path);
      final response = request.response;
      switch (request.uri.path) {
        case '/over-limit':
          response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          response.add(gzip.encode(List.filled(256 * 1024 + 1, 32)));
        case '/invalid-redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, 'file:///icon.svg');
        case '/credential-redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'http://user:password@127.0.0.1:${server.port}/must-not-visit',
          );
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    for (final path in [
      '/missing',
      '/over-limit',
      '/invalid-redirect',
      '/credential-redirect',
    ]) {
      expect(await loadPaymentChannelIcon(base.resolve(path)), isNull);
    }
    expect(await loadPaymentChannelIcon(Uri.parse('file:///icon.svg')), isNull);
    expect(visited, [
      '/missing',
      '/over-limit',
      '/invalid-redirect',
      '/credential-redirect',
    ]);
  });
}
