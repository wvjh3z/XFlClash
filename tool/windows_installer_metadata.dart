// Public Windows installer metadata; no runtime flavor secrets are consumed.
import 'dart:convert';

class WindowsInstallerMetadata {
  const WindowsInstallerMetadata._({
    required this.publisherName,
    this.publisherUrl,
    this.supportUrl,
    this.updatesUrl,
  });

  factory WindowsInstallerMetadata.fromYaml(
    Object? document, {
    required String defaultPublisher,
  }) {
    if (document != null && document is! Map) {
      throw const FormatException('Installer metadata must be a YAML map');
    }
    final values = document as Map? ?? const {};
    const keys = {'publisherName', 'publisherUrl', 'supportUrl', 'updatesUrl'};
    if (values.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unknown installer metadata field');
    }
    String? text(String key) {
      final value = values[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('Installer $key must be a string');
      }
      if (RegExp(r'[\x00-\x1f\x7f{}]').hasMatch(value)) {
        throw FormatException('Installer $key contains unsupported characters');
      }
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    String? url(String key) {
      final value = text(key);
      if (value == null) return null;
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          RegExp(r'\s').hasMatch(value)) {
        throw FormatException('Installer $key must be an absolute HTTP(S) URL');
      }
      return value;
    }

    final publisher = text('publisherName') ?? defaultPublisher.trim();
    if (publisher.isEmpty || RegExp(r'[\x00-\x1f\x7f{}]').hasMatch(publisher)) {
      throw const FormatException('Installer publisherName is invalid');
    }
    return WindowsInstallerMetadata._(
      publisherName: publisher,
      publisherUrl: url('publisherUrl'),
      supportUrl: url('supportUrl'),
      updatesUrl: url('updatesUrl'),
    );
  }

  final String publisherName;
  final String? publisherUrl;
  final String? supportUrl;
  final String? updatesUrl;
}

/// Use the key the installed maker actually reads; remove its legacy aliases.
String injectWindowsInstallerConfig(
  String source,
  WindowsInstallerMetadata metadata,
) {
  final cleaned = source.replaceAll(
    RegExp(
      r'^(?:publisher|publisher_name|publisher_url|appPublisher|appPublisherUrl):[^\r\n]*(?:\r?\n|$)',
      multiLine: true,
    ),
    '',
  );
  final separator = cleaned.isEmpty || cleaned.endsWith('\n') ? '' : '\n';
  return '$cleaned${separator}publisher_name: ${jsonEncode(metadata.publisherName)}\n';
}

/// Owned template directives are independent of the maker's shared URL field.
String injectWindowsInstallerLinks(
  String source,
  WindowsInstallerMetadata metadata,
) {
  const start = '; xboard-installer-links:start';
  const end = '; xboard-installer-links:end';
  final starts = RegExp(
    '^${RegExp.escape(start)}\r?\$',
    multiLine: true,
  ).allMatches(source).toList();
  final ends = RegExp(
    '^${RegExp.escape(end)}\r?\$',
    multiLine: true,
  ).allMatches(source).toList();
  if (starts.length != 1 ||
      ends.length != 1 ||
      starts.single.end >= ends.single.start) {
    throw const FormatException(
      'Installer link markers are missing or invalid',
    );
  }
  final links = {
    'AppPublisherURL': metadata.publisherUrl,
    'AppSupportURL': metadata.supportUrl,
    'AppUpdatesURL': metadata.updatesUrl,
  };
  final content = StringBuffer('\n');
  for (final entry in links.entries) {
    if (entry.value != null) content.writeln('${entry.key}=${entry.value}');
  }
  return source.replaceRange(
    starts.single.end,
    ends.single.start,
    content.toString(),
  );
}
