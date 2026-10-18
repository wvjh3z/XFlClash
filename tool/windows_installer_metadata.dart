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

/// Installer-only identity. Never derive it from the FlClash pubspec version.
class WindowsInstallerVersion {
  WindowsInstallerVersion(String productVersion, String buildNumber) {
    final match = RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(productVersion);
    final number = int.tryParse(buildNumber);
    if (match == null ||
        match.end != productVersion.length ||
        !RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(buildNumber) ||
        number == null ||
        number.toString() != buildNumber ||
        number > 65535) {
      throw const FormatException(
        'Installer product version/build number is invalid',
      );
    }
    final parts = [for (var i = 1; i <= 3; i++) int.tryParse(match.group(i)!)];
    if (parts.any((part) => part == null || part > 65535)) {
      throw const FormatException(
        'Installer version component exceeds Windows limits',
      );
    }
    displayVersion = '$productVersion (build $number)';
    appVerName = '{{DISPLAY_NAME}} $productVersion ({cm:XbBuildLabel} $number)';
    fileVersion = '${parts.join('.')}.$number';
  }

  late final String displayVersion;
  late final String appVerName;
  late final String fileVersion;
}

String injectWindowsInstallerVersion(
  String source,
  WindowsInstallerVersion version,
) {
  const start = '; xboard-installer-version:start';
  const end = '; xboard-installer-version:end';
  final starts = RegExp(
    '^${RegExp.escape(start)}\\r?\$',
    multiLine: true,
  ).allMatches(source).toList();
  final ends = RegExp(
    '^${RegExp.escape(end)}\\r?\$',
    multiLine: true,
  ).allMatches(source).toList();
  if (starts.length != 1 ||
      ends.length != 1 ||
      starts.single.end >= ends.single.start) {
    throw const FormatException(
      'Installer version markers are missing or invalid',
    );
  }
  final outside =
      source.substring(0, starts.single.start) +
      source.substring(ends.single.end);
  if (RegExp(
    r'^\s*(AppVersion|AppVerName|VersionInfoVersion|VersionInfoProductTextVersion)\s*=',
    multiLine: true,
  ).hasMatch(outside)) {
    throw const FormatException(
      'Installer version directives outside owned block',
    );
  }
  return source.replaceRange(
    starts.single.end,
    ends.single.start,
    '\nAppVersion=${version.displayVersion}\n'
    'AppVerName=${version.appVerName}\n'
    'VersionInfoVersion=${version.fileVersion}\n'
    'VersionInfoProductTextVersion=${version.displayVersion}\n',
  );
}
