import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'xboard_release_dio.dart';

final xbUpdateSourceProbeFactoryProvider = Provider<XbUpdateSourceProbe Function()>(
  (_) => () => XbUpdateSourceProbe(),
);

/// Limit before Dio's response handler subscribes/buffers. Truncating only the
/// consumer's sample is too late when a server ignores Range and streams fast.
class _SampleAdapter implements HttpClientAdapter {
  _SampleAdapter(this.delegate, this.limit);
  final HttpClientAdapter delegate;
  final int limit;

  Stream<Uint8List> _bounded(Stream<Uint8List> source) {
    var remaining = limit;
    var finished = false;
    var cancelRequested = false;
    StreamSubscription<Uint8List>? subscription;
    Future<void>? stopping;
    late final StreamController<Uint8List> output;

    Future<void> cancelSource() {
      cancelRequested = true;
      if (subscription == null) return Future<void>.value();
      // Dio may not await stream cancellation. Consume cleanup failures here;
      // active response errors still travel through onError below.
      return stopping ??= Future<void>.sync(() => subscription!.cancel()).catchError((Object _) {});
    }

    void finish({bool cancel = true}) {
      if (finished) return;
      finished = true;
      if (cancel) unawaited(cancelSource());
      unawaited(output.close());
    }

    // Explicit ownership avoids async* waiting for another yield before
    // cancelling a hanging source or leaking its late socket error.
    output = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        subscription = source.listen((chunk) {
          if (finished || chunk.isEmpty) return;
          final sample = chunk.length <= remaining
              ? chunk : Uint8List.sublistView(chunk, 0, remaining);
          remaining -= sample.length;
          output.add(sample);
          if (remaining == 0) finish();
        }, onError: (Object error, StackTrace stack) {
          if (finished) return;
          output.addError(error, stack);
          finish();
        }, onDone: () => finish(cancel: false));
        if (cancelRequested) unawaited(cancelSource());
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        finished = true;
        return cancelSource();
      },
    );
    return output.stream;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    final body = await delegate.fetch(options, requestStream, cancelFuture);
    body.stream = _bounded(body.stream);
    return body;
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

/// One bounded GET round. Confirmed sources move first; unconfirmed sources
/// remain usable fallbacks. Availability is not package integrity verification.
class XbUpdateSourceProbe {
  XbUpdateSourceProbe({
    Dio? dio,
    this.timeout = const Duration(seconds: 3),
    this.concurrency = 2,
    this.sampleLimit = 100 * 1024,
  }) : assert(concurrency > 0),
       assert(sampleLimit > 0),
       _dio = dio ?? buildReleasedIsolatedDio(timeout: timeout) {
    _dio.httpClientAdapter = _SampleAdapter(_dio.httpClientAdapter, sampleLimit);
  }

  final Dio _dio;
  final Duration timeout;
  final int concurrency;
  final int sampleLimit;
  final _clock = Stopwatch();
  final _answer = Completer<List<String>>();
  final _tokens = <CancelToken>{};
  List<String> _urls = const [];
  final _confirmed = <int>{};
  Timer? _timer;
  var _cursor = 0;
  var _workers = 0;
  var _started = false;
  var _closed = false;

  bool get _withinBudget => !_closed && _clock.elapsed < timeout;

  Future<List<String>> run(List<String> orderedUrls) {
    if (_started || _closed) return _answer.future;
    _started = true;
    _urls = List.unmodifiable(orderedUrls.toSet());
    _clock.start();
    if (_urls.isEmpty || timeout <= Duration.zero) {
      cancel();
      return _answer.future;
    }
    _workers = _urls.length < concurrency ? _urls.length : concurrency;
    _timer = Timer(timeout, cancel);
    for (var i = 0; i < _workers; i++) {
      unawaited(_work());
    }
    return _answer.future;
  }

  Future<void> _work() async {
    try {
      while (_withinBudget && _cursor < _urls.length) {
        final index = _cursor++;
        if (await _probe(_urls[index]) && _withinBudget) _confirmed.add(index);
      }
    } finally {
      if (--_workers == 0) cancel();
    }
  }

  Future<bool> _probe(String url) async {
    final token = CancelToken();
    _tokens.add(token);
    try {
      final response = await _dio.get<ResponseBody>(url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-${sampleLimit - 1}', 'Accept-Encoding': 'identity'},
          validateStatus: (_) => true,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final body = response.data;
      if (body == null) return false;
      final type = (response.headers.value(Headers.contentTypeHeader) ?? '').toLowerCase();
      if (!_withinBudget ||
          (response.statusCode != 200 && response.statusCode != 206) ||
          type.startsWith('text/') || type.contains('json') || type.contains('xml')) {
        await body.stream.listen((_) {}).cancel();
        return false;
      }
      final sample = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (!_withinBudget) return false;
        final remaining = sampleLimit - sample.length;
        sample.add(chunk.length <= remaining ? chunk : Uint8List.sublistView(chunk, 0, remaining));
        if (sample.length == sampleLimit) break;
      }
      if (sample.isEmpty || !_withinBudget) return false;
      final prefix = String.fromCharCodes(sample.takeBytes()).trimLeft().toLowerCase();
      return !prefix.startsWith('<!doctype html') && !prefix.startsWith('<html');
    } catch (_) {
      return false;
    } finally {
      token.cancel('update GET probe finished');
      _tokens.remove(token);
    }
  }

  /// Also settles callers when a transport ignores cancellation. No late result
  /// can mutate the returned, immutable order. Network buffers may exceed the
  /// retained sample; no whole-body buffering or file download is performed.
  void cancel() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    for (final token in _tokens) {
      token.cancel('update GET round finished');
    }
    _dio.close(force: true);
    _answer.complete(List.unmodifiable([
      for (var i = 0; i < _urls.length; i++) if (_confirmed.contains(i)) _urls[i],
      for (var i = 0; i < _urls.length; i++) if (!_confirmed.contains(i)) _urls[i],
    ]));
  }
}
