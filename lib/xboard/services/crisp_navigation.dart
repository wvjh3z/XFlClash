import 'crisp_appimage_browser.dart';

/// Only top-level navigation is routed here; Crisp frames keep their own
/// script/resource requests. HTTP attachments open in the system browser;
/// blob attachments stay in WebView so its native download handler can save.
enum CrispNavigation { internal, external, blocked }

CrispNavigation crispNavigation(String url, Uri page) {
  final uri = Uri.tryParse(url);
  if (uri == null) return CrispNavigation.blocked;
  if (uri.replace(fragment: '') == page.replace(fragment: '') ||
      url == 'about:blank' ||
      url.startsWith('blob:')) {
    return CrispNavigation.internal;
  }
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty) {
    return CrispNavigation.external;
  }
  if (uri.scheme == 'mailto') return CrispNavigation.external;
  return CrispNavigation.blocked;
}

/// Visitor chat, never the operator dashboard; carries no account credentials.
Uri crispVisitorUri(String websiteId) => Uri.https(
  'go.crisp.chat',
  '/chat/embed/',
  {'website_id': websiteId.trim()},
);

/// Verify launcher/runtime markers belong to this executable.
/// Inherited markers alone must not change a DEB/RPM process transport.
bool crispUsesExternalBrowser({
  bool? isLinux,
  Map<String, String>? environment,
  String? executable,
}) =>
    crispAppImageRoot(
      isLinux: isLinux,
      environment: environment,
      executable: executable,
    ) !=
    null;
