import 'dart:async' show unawaited;
import 'dart:io';

import 'package:dio/dio.dart';

/// Downloads one mirror into a task-private file. A partial file is never
/// carried to a different URL or a later user action.
Future<void> xbDownloadUpdateSource(
  Dio dio, String url, File file, {
  required void Function(int, int) onProgress,
  required bool Function() canRecover,
  CancelToken? cancelToken,
}) async {
  final uri = Uri.parse(url);
  String? validator;
  int? originalSize;
  var startedFull = false;

  void checkCancelled() {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
  }

  DioException invalid(String message) => DioException(
    requestOptions: RequestOptions(path: url), error: message,
  );

  String? header(Headers headers, String name) {
    final v = headers[name];
    return v != null && v.length == 1 ? v.single.trim() : null;
  }

  Future<void> fetch({int? offset}) async {
    checkCancelled();
    final request = CancelToken();
    unawaited(cancelToken?.whenCancel.then((_) => request.cancel('Update cancelled')));
    var status = 0;
    var base = 0;
    int? expected;
    try {
      await dio.download(
        url,
        (Headers h) {
          checkCancelled();
          final rawLength = header(h, HttpHeaders.contentLengthHeader);
          final length = rawLength == null ? null : int.tryParse(rawLength);
          if (h[HttpHeaders.contentLengthHeader] != null && (length == null || length < 0)) {
            if (offset != null) throw const _RestartSource();
            throw invalid('Invalid update response length');
          }
          final encoding = h[HttpHeaders.contentEncodingHeader];
          final identity = encoding == null ||
              (encoding.length == 1 && encoding.single.trim().toLowerCase() == 'identity');
          final tag = header(h, HttpHeaders.etagHeader);
          // Dio adds the resolved URL and redirect count before asking for
          // the destination path. Require exactly one unambiguous value.
          final sameSource = header(h, 'redirects') == '0' && header(h, 'uri') == uri.toString();
          if (status == HttpStatus.ok && h[HttpHeaders.contentRangeHeader] == null) {
            startedFull = true;
            expected = identity ? length : null;
            validator = sameSource && identity && tag != null &&
                    RegExp(r'^"[\x21\x23-\x7e]+"$').hasMatch(tag)
                ? tag : null;
            originalSize = expected;
            // If-Range was ignored or the representation changed. Reuse this
            // complete 200 response, but never prepend the old prefix to it.
            if (offset != null) {
              file.writeAsBytesSync(const []);
              onProgress(0, expected ?? -1);
            }
          } else if (offset != null && status == HttpStatus.partialContent) {
            final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
                .firstMatch(header(h, HttpHeaders.contentRangeHeader) ?? '');
            final start = int.tryParse(range?.group(1) ?? '');
            final end = int.tryParse(range?.group(2) ?? '');
            final size = int.tryParse(range?.group(3) ?? '');
            if (!sameSource || !identity || validator == null || tag != validator ||
                start != offset || size == null || offset >= size || end != size - 1 ||
                (originalSize != null && size != originalSize) || length != size - offset ||
                file.lengthSync() != offset) {
              throw const _RestartSource();
            }
            base = offset;
            expected = size;
          } else {
            if (offset != null) throw const _RestartSource();
            throw invalid('Expected a complete update response');
          }
          return file.path;
        },
        deleteOnError: false,
        fileAccessMode: offset == null ? FileAccessMode.write : FileAccessMode.append,
        cancelToken: request,
        options: Options(
          receiveDataWhenStatusError: false,
          followRedirects: offset == null,
          headers: {
            HttpHeaders.acceptEncodingHeader: 'identity',
            if (offset != null) HttpHeaders.rangeHeader: 'bytes=$offset-',
            if (offset != null) HttpHeaders.ifRangeHeader: validator!,
          },
          validateStatus: (code) {
            status = code ?? 0;
            return status == HttpStatus.ok || status == HttpStatus.partialContent;
          },
        ),
        onReceiveProgress: (n, _) => onProgress(base + n, expected ?? -1),
      );
      checkCancelled();
      final size = await file.length();
      if (size == 0 || (expected != null && size != expected)) {
        throw invalid('Incomplete update response');
      }
    } finally {
      // Also closes unconsumed bodies rejected by the destination callback.
      request.cancel('Update source finished');
    }
  }

  try {
    await fetch();
    return;
  } on DioException catch (error) {
    checkCancelled();
    if (!canRecover() || !startedFull || error.error is FileSystemException ||
        !await file.exists()) {
      rethrow;
    }
    final offset = await file.length();
    if (offset <= 0 || (originalSize != null && offset >= originalSize!)) rethrow;
    checkCancelled();
    if (!canRecover()) rethrow;
    if (validator != null) {
      try {
        await fetch(offset: offset);
        return;
      } on _RestartSource {
        // A malformed 206 is not a usable file, even if its bytes look plausible.
      } on DioException catch (rangeError) {
        final code = rangeError.response?.statusCode;
        if (code != 416 && !(code != null && code >= 300 && code < 400)) rethrow;
      }
    }
    checkCancelled();
    if (!canRecover()) throw invalid('Update retry requires user action');
    onProgress(0, -1);
    await fetch(); // At most one Range and one clean fallback on this mirror.
  }
}

class _RestartSource implements Exception {
  const _RestartSource();
}
