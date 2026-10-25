import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/crisp_navigation.dart';

void main() {
  final page = Uri.file('/tmp/中文客服/index.html');
  test(
    'local page reload and blob download stay inside; other files are denied',
    () {
      for (final url in [
        page.toString(),
        '$page#section',
        'about:blank',
        'blob:null/attachment',
      ]) {
        expect(crispNavigation(url, page), CrispNavigation.internal);
      }
      for (final url in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'data:text/html,hello',
        'custom:command',
      ]) {
        expect(crispNavigation(url, page), CrispNavigation.blocked);
      }
    },
  );
  test(
    'normal and attachment links go to browser without navigating chat away',
    () {
      for (final url in [
        'https://example.invalid/help',
        'https://storage.crisp.chat/file.png',
        'mailto:support@example.invalid',
      ]) {
        expect(crispNavigation(url, page), CrispNavigation.external);
      }
      expect(
        crispNavigation('https://user:password@example.invalid/', page),
        CrispNavigation.blocked,
      );
    },
  );
  test(
    'both brands get visitor links with no account fields or operator URL',
    () {
      for (final site in ['brand-a-site', 'brand-b-site']) {
        final uri = crispVisitorUri(site);
        expect(uri.host, 'go.crisp.chat');
        expect(uri.path, '/chat/embed/');
        expect(uri.queryParameters, {'website_id': site});
      }
    },
  );
  test('AppImage marker must belong to the current executable', () {
    for (final name in ['omofly', 'daishu']) {
      final env = {
        'XBOARD_APPIMAGE_ROOT': '/tmp/image',
        'XBOARD_APPIMAGE_EXECUTABLE': '/tmp/image/$name',
      };
      expect(
        crispUsesExternalBrowser(
          isLinux: true,
          environment: env,
          executable: '/tmp/image/$name',
        ),
        isTrue,
      );
      expect(
        crispUsesExternalBrowser(
          isLinux: false,
          environment: env,
          executable: '/tmp/image/$name',
        ),
        isFalse,
      );
      expect(
        crispUsesExternalBrowser(
          isLinux: true,
          environment: env,
          executable: '/usr/bin/$name',
        ),
        isFalse,
      );
    }
    expect(
      crispUsesExternalBrowser(
        isLinux: true,
        environment: {'APPIMAGE': '/tmp/a.AppImage'},
        executable: '/usr/bin/app',
      ),
      isFalse,
    );
    expect(
      crispUsesExternalBrowser(
        isLinux: true,
        environment: {'APPIMAGE': '/tmp/a.AppImage', 'APPDIR': '/tmp/image'},
        executable: '/tmp/image/app',
      ),
      isTrue,
    );
    expect(
      crispUsesExternalBrowser(
        isLinux: true,
        environment: {'APPDIR': '/tmp/image'},
        executable: '/usr/bin/app',
      ),
      isFalse,
    );
  });
}
