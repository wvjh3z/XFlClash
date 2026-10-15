import 'package:sentry_flutter/sentry_flutter.dart';

/// Filters application data before the Dart SDK persists or sends it.
///
/// Native crash handlers can send their own envelopes without running Dart
/// callbacks. Their server-side scrubbing is a separate deployment requirement.
class SentrySanitizer {
  SentrySanitizer._();

  static const redacted = '***';
  static const sensitiveKeys = [
    'token',
    'password',
    'passwd',
    'pwd',
    'email',
    'uuid',
    'authorization',
    'authdata',
    'cookie',
    'secret',
    'apikey',
    'accesskey',
    'sessionid',
    'username',
    'userid',
    'ipaddress',
  ];

  static final _email = RegExp(
    r'[A-Z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}',
    caseSensitive: false,
  );
  static final _uuid = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );
  static final _bearer = RegExp(
    r'\bBearer\s+[A-Za-z0-9._~+/=\-]+',
    caseSensitive: false,
  );
  static final _url = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);
  static final _credentials = RegExp(
    r'''(["']?(?:[\w.-]*(?:token|password|passwd|pwd|email|uuid|authorization|auth[_-]?data|secret|api[_-]?key|access[_-]?key|session[_-]?id|cookie)[\w.-]*)["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]]+)''',
    caseSensitive: false,
  );

  static bool isSensitiveKey(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return sensitiveKeys.any(normalized.contains);
  }

  static String scrubText(String value) {
    var clean = value.replaceAllMapped(_url, (match) {
      final original = match[0]!;
      final uri = Uri.tryParse(original);
      if (uri == null) return original;
      // All query/fragment values are private. Subscription credentials can use
      // non-standard parameter names, so a name allowlist is insufficient.
      return uri
          .replace(
            userInfo: '',
            query: uri.hasQuery ? redacted : null,
            fragment: uri.hasFragment ? redacted : null,
          )
          .toString();
    });
    clean = clean.replaceAll(_bearer, 'Bearer $redacted');
    clean = clean.replaceAllMapped(
      _credentials,
      (match) => '${match[1]}$redacted',
    );
    clean = clean.replaceAll(_email, redacted);
    return clean.replaceAll(_uuid, redacted);
  }

  static dynamic scrubValue(dynamic value) {
    if (value is Map) {
      final clean = <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): isSensitiveKey(entry.key.toString())
              ? redacted
              : scrubValue(entry.value),
      };
      // Registers and several other SDK interfaces require Map<String,String>.
      return clean.values.every((element) => element is String)
          ? clean.cast<String, String>()
          : clean;
    }
    if (value is List) {
      // Some SDK protocol readers require List<String> directly (for example
      // frame pre_context/post_context), rather than accepting List<dynamic>.
      if (value.every((element) => element is String)) {
        return value.cast<String>().map(scrubText).toList(growable: false);
      }
      return value.map(scrubValue).toList(growable: false);
    }
    return value is String ? scrubText(value) : value;
  }

  static Map<String, dynamic> scrubData(Map<String, dynamic> data) =>
      scrubValue(data) as Map<String, dynamic>;

  static Breadcrumb scrubBreadcrumb(Breadcrumb breadcrumb) =>
      Breadcrumb.fromJson(scrubData(breadcrumb.toJson()));

  static SentryEvent scrubEvent(SentryEvent event) {
    final json = event.toJson();
    final clean = scrubData(json);
    // Debug IDs can resemble account UUIDs. Preserve only defined diagnostic
    // identity fields; debug/source paths and unknown metadata stay filtered.
    final originalImages = (json['debug_meta'] as Map?)?['images'] as List?;
    final cleanImages = (clean['debug_meta'] as Map?)?['images'] as List?;
    if (originalImages != null && cleanImages != null) {
      for (var i = 0; i < originalImages.length; i++) {
        _restoreFields(originalImages[i] as Map, cleanImages[i] as Map, const [
          'debug_id',
          'uuid',
          'code_id',
          'image_addr',
          'image_vmaddr',
        ]);
      }
    }
    for (final group in ['exception', 'threads']) {
      final originalValues = (json[group] as Map?)?['values'] as List?;
      final cleanValues = (clean[group] as Map?)?['values'] as List?;
      if (originalValues == null || cleanValues == null) continue;
      for (var i = 0; i < originalValues.length; i++) {
        final stack = (originalValues[i] as Map)['stacktrace'];
        final safeStack = (cleanValues[i] as Map)['stacktrace'];
        if (stack is! Map || safeStack is! Map) continue;
        _restoreFields(stack, safeStack, const ['build_id', 'base_addr']);
        // Frame addresses/functions survive normal filtering. URL paths,
        // source context and local variables must never be restored wholesale.
      }
    }
    // No application account identity is needed to diagnose a crash.
    if (json.containsKey('user')) clean.remove('user');
    final result = SentryEvent.fromJson(clean);
    // sentry 9.22.0 SentryThread.fromJson reads its frame object from the
    // thread level rather than stacktrace. Reassign the nested stack explicitly
    // so this filtering round-trip cannot erase thread frames.
    final threadValues = (clean['threads'] as Map?)?['values'] as List?;
    if (threadValues != null && result.threads != null) {
      for (var i = 0; i < threadValues.length; i++) {
        final stack = (threadValues[i] as Map)['stacktrace'];
        result.threads![i].stacktrace = stack is Map<String, dynamic>
            ? SentryStackTrace.fromJson(stack)
            : null;
      }
    }
    return result;
  }

  static void _restoreFields(Map original, Map clean, List<String> keys) {
    for (final key in keys) {
      if (original.containsKey(key)) clean[key] = original[key];
    }
  }
}
