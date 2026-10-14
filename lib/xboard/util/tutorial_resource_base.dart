/// Canonical directory URL for tutorial resources, independent of API mirrors.
Uri? tutorialResourceBase(String? raw) {
  try {
    final uri = Uri.tryParse(raw?.trim() ?? '');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        (uri.hasPort && (uri.port <= 0 || uri.port > 65535))) {
      return null;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  } on FormatException {
    return null;
  }
}
