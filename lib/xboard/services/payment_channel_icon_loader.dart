import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:html/parser.dart' as html;

const _maxBytes = 256 * 1024;
const _maxRedirects = 3;
const _timeout = Duration(seconds: 8);
const _redirectStatuses = {301, 302, 303, 307, 308};
final _svgRoot = RegExp(r'<svg(?:\s|/?>)', caseSensitive: false);
final _invalidLocation = RegExp(r'[\x00-\x1f\x7f\\]|^(?:\w+:)?//[^/?#]*@');

bool _isNetworkImage(Uri uri) =>
    (uri.isScheme('https') || uri.isScheme('http')) &&
    uri.host.isNotEmpty &&
    !uri.authority.contains('@') &&
    (!uri.hasPort || (uri.port > 0 && uri.port <= 65535));

/// Decorative artwork is fetched anonymously, outside the authenticated SDK.
/// A failed, unsafe or oversized resource is indistinguishable from no icon.
Future<({Uint8List bytes, bool isSvg})?> loadPaymentChannelIcon(Uri uri) async {
  HttpClient? client;
  try {
    if (!_isNetworkImage(uri)) return null;
    client = HttpClient()..connectionTimeout = _timeout;
    return await _readIcon(client, uri).timeout(_timeout);
  } on Exception {
    return null;
  } finally {
    client?.close(force: true);
  }
}

Future<({Uint8List bytes, bool isSvg})?> _readIcon(
  HttpClient client,
  Uri uri,
) async {
  for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
    final request = await client.getUrl(uri);
    // Validate every new location before any I/O. No SDK headers or cookies.
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'image/svg+xml, image/*');
    final response = await request.close();
    if (_redirectStatuses.contains(response.statusCode)) {
      final location = response.headers.value(HttpHeaders.locationHeader)?.trim();
      if (redirects == _maxRedirects ||
          location == null ||
          location.isEmpty ||
          _invalidLocation.hasMatch(location)) {
        return null;
      }
      final next = uri.resolve(location);
      if (!_isNetworkImage(next) ||
          (uri.isScheme('https') && !next.isScheme('https'))) {
        return null;
      }
      // Don't wait for an arbitrary redirect body before following it.
      await response.listen(null).cancel();
      uri = next;
      continue;
    }
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > _maxBytes) {
      return null;
    }

    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (buffer.length + chunk.length > _maxBytes) return null;
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    if (bytes.isEmpty) return null;
    final mime = response.headers.contentType?.mimeType;
    final sample = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
    final isSvg =
        mime == 'image/svg+xml' ||
        uri.path.toLowerCase().endsWith('.svg') ||
        _svgRoot.hasMatch(utf8.decode(sample, allowMalformed: true));
    return (bytes: isSvg ? normalizePaymentSvgPaint(bytes) : bytes, isSvg: isSvg);
  }
  return null;
}

/// flutter_svg does not apply embedded stylesheets. Illustrator exports often
/// use plain class selectors even for two flat colors. Inline only that small
/// supported subset; don't reinterpret external CSS, URLs or complex selectors.
Uint8List normalizePaymentSvgPaint(Uint8List bytes) {
  final source = utf8.decode(bytes, allowMalformed: true);
  if (!source.contains('<style') || !source.contains('class=')) return bytes;
  final svg = html.parseFragment(source).querySelector('svg');
  if (svg == null) return bytes;
  final rules = <(String, Map<String, String>)>[];
  final selector = RegExp(r'\.([a-zA-Z_][\w-]*)\s*\{([^{}]*)\}\s*');
  final paint = RegExp(r'^(fill|stroke)\s*:\s*(#[\da-fA-F]{6}|#[\da-fA-F]{3}|none)$');
  final sheets = svg.querySelectorAll('style');
  for (final sheet in sheets) {
    final css = sheet.text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '').trim();
    var pos = 0;
    while (pos < css.length) {
      final rule = selector.matchAsPrefix(css, pos);
      if (rule == null) return bytes;
      final props = <String, String>{};
      for (final decl in rule[2]!.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
        final entry = paint.firstMatch(decl);
        if (entry == null) return bytes;
        props[entry[1]!] = entry[2]!;
      }
      rules.add((rule[1]!, props));
      pos = rule.end;
    }
  }
  if (rules.isEmpty || rules.length > 128) return bytes;
  for (final el in [svg, ...svg.querySelectorAll('[class]')]) {
    for (final (name, props) in rules) {
      if (el.classes.contains(name)) el.attributes.addAll(props);
    }
    // Existing inline style attributes retain precedence over fill/stroke.
  }
  for (final sheet in sheets) {
    sheet.remove();
  }
  return Uint8List.fromList(utf8.encode(svg.outerHtml));
}
