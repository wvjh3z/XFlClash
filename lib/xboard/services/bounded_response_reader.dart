import 'dart:typed_data';

import 'package:dio/dio.dart';

/// The decoded response exceeded its application limit. Contains no URL/data.
class ResponseTooLargeException implements Exception {
  const ResponseTooLargeException(this.limit);
  final int limit;
  @override
  String toString() => 'Response exceeds $limit decoded bytes';
}

/// Read decoded chunks, rejecting the overflowing chunk before retaining it.
/// Content-Length may describe compressed bytes and is deliberately not trusted.
/// The supplied token must be request-scoped (never shared by race siblings).
/// Callers already allocate one token per candidate; cancellation stays synchronous.
Future<Response<Uint8List>> readBoundedResponse(
  Dio dio,
  Uri uri, {
  required int maxBytes,
  CancelToken? cancelToken,
  Duration? sendTimeout,
  Duration? receiveTimeout,
}) async {
  if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
  final local = cancelToken ?? CancelToken();
  final bytes = BytesBuilder(copy: false);
  var completed = false;
  try {
    final response = await dio.getUri<ResponseBody>(
      uri,
      cancelToken: local,
      options: Options(
        responseType: ResponseType.stream,
        sendTimeout: sendTimeout,
        receiveTimeout: receiveTimeout,
        // Bound error documents as well, then let callers classify HTTP errors.
        validateStatus: (status) => status != null,
      ),
    );
    final body = response.data;
    if (body != null) {
      await for (final chunk in body.stream) {
        if (local.isCancelled) throw local.cancelError!;
        if (chunk.length > maxBytes - bytes.length) {
          throw ResponseTooLargeException(maxBytes);
        }
        bytes.add(chunk);
      }
    }
    if (local.isCancelled) throw local.cancelError!;
    final result = Response<Uint8List>(
      requestOptions: response.requestOptions,
      data: bytes.takeBytes(),
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      extra: response.extra,
    );
    completed = true;
    return result;
  } finally {
    bytes.clear();
    // Dio's cancellation closes the source response, not just our subscription.
    if (!completed || cancelToken == null) {
      local.cancel('Bounded response reader finished');
    }
  }
}
