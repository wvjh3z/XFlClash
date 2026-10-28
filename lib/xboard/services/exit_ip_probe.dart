import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/constant.dart' show browserUa;

import 'bounded_response_reader.dart';

class XbExitIpResult {
  const XbExitIpResult(this.ip, this.countryCode);
  final String ip;
  final String? countryCode;
}

class XbExitIpSource {
  const XbExitIpSource(this.url, this.ipKey, this.countryKey);
  final String url;
  final String ipKey;
  final String countryKey;

  XbExitIpResult? parse(Object? body) {
    if (body is! Map<String, dynamic>) return null;
    final ip = body[ipKey];
    if (ip is! String || InternetAddress.tryParse(ip.trim()) == null) {
      return null;
    }
    final country = body[countryKey];
    return XbExitIpResult(
      ip.trim(),
      country is String && RegExp(r'^[a-zA-Z]{2}$').hasMatch(country)
          ? country.toUpperCase()
          : null,
    );
  }
}

const xbLegacyExitIpSources = [
  XbExitIpSource('https://ipwho.is', 'ip', 'country_code'),
  XbExitIpSource('https://api.myip.com', 'ip', 'cc'),
  XbExitIpSource('https://ipapi.co/json', 'ip', 'country_code'),
  XbExitIpSource('https://ident.me/json', 'ip', 'cc'),
  XbExitIpSource('http://ip-api.com/json', 'query', 'countryCode'),
  XbExitIpSource('https://api.ip.sb/geoip', 'ip', 'country_code'),
  XbExitIpSource('https://ipinfo.io/json', 'ip', 'country'),
];

/// One round owns one new client. HttpClient() inherits the host's global
/// proxy/authentication/certificate policy; never install an IP-only override.
Dio createExitIpDio() {
  final dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient(),
  );
  return dio;
}

/// Seven concurrent candidates, first valid IP wins. Cancellation also settles
/// callers, even if a transport does not cooperate with its cancel token.
class XbExitIpProbe {
  XbExitIpProbe({
    Dio? dio,
    this.sources = xbLegacyExitIpSources,
    this.timeout = const Duration(seconds: 10),
  }) : _dio = dio ?? createExitIpDio();

  final Dio _dio;
  final List<XbExitIpSource> sources;
  final Duration timeout;
  final List<CancelToken> _tokens = [];
  final Completer<XbExitIpResult?> _answer = Completer();
  bool _started = false;
  bool _closed = false;

  Future<XbExitIpResult?> run() {
    if (_started || _closed) return _answer.future;
    _started = true;
    if (sources.isEmpty) {
      cancel();
      return _answer.future;
    }
    var remaining = sources.length;
    for (final source in sources) {
      final token = CancelToken();
      _tokens.add(token);
      unawaited(() async {
        try {
          final response =
              await readBoundedResponse(
                _dio,
                Uri.parse(source.url),
                maxBytes: 64 * 1024,
                cancelToken: token,
                sendTimeout: timeout,
                receiveTimeout: timeout,
              ).timeout(
                timeout,
                onTimeout: () {
                  token.cancel('IP lookup deadline');
                  throw TimeoutException('IP lookup deadline');
                },
              );
          if (_closed || response.statusCode != 200) return;
          final value = source.parse(jsonDecode(utf8.decode(response.data!)));
          if (value != null && !_answer.isCompleted) {
            _answer.complete(value);
            cancel();
          }
        } on Exception {
          // A failed source must not beat a valid competitor or create an Issue.
        } finally {
          token.cancel('IP source finished');
          if (--remaining == 0) cancel();
        }
      }());
    }
    return _answer.future;
  }

  void cancel() {
    if (_closed) return;
    _closed = true;
    for (final token in _tokens) {
      token.cancel('IP round finished');
    }
    _dio.close(force: true);
    if (!_answer.isCompleted) _answer.complete(null);
  }
}
