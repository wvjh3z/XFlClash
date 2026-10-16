import 'package:fl_clash/xboard/services/xb_update_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show AppDownload, AppUpdateModel;

AppUpdateModel _update(String region, List<AppDownload> downloads) =>
    AppUpdateModel(
      versionCode: 2,
      versionName: '2.0.0',
      region: region,
      downloads: downloads,
      sha256: '',
      changelog: '',
      force: false,
    );

void main() {
  const downloads = [
    AppDownload(url: 'https://cn-one.example/app', region: 'cn'),
    AppDownload(url: 'https://other.example/app', region: 'unknown'),
    AppDownload(url: 'https://overseas-one.example/app', region: 'overseas'),
    AppDownload(url: 'https://cn-two.example/app', region: 'cn'),
    AppDownload(url: 'https://overseas-two.example/app', region: 'overseas'),
  ];

  group('xbSortedUpdateUrls', () {
    test('海外地区优先海外镜像，两组均保留后端顺序', () {
      expect(xbSortedUpdateUrls(_update('overseas', downloads)), [
        'https://overseas-one.example/app',
        'https://overseas-two.example/app',
        'https://cn-one.example/app',
        'https://other.example/app',
        'https://cn-two.example/app',
      ]);
    });

    test('国内地区优先国内镜像，不移动其他地区的相对顺序', () {
      expect(xbSortedUpdateUrls(_update('cn', downloads)), [
        'https://cn-one.example/app',
        'https://cn-two.example/app',
        'https://other.example/app',
        'https://overseas-one.example/app',
        'https://overseas-two.example/app',
      ]);
    });

    test('unknown 不优先同名未知源，恢复后端顺序', () {
      expect(xbSortedUpdateUrls(_update('unknown', downloads)), [
        'https://cn-one.example/app',
        'https://other.example/app',
        'https://overseas-one.example/app',
        'https://cn-two.example/app',
        'https://overseas-two.example/app',
      ]);
    });

    test('过滤非绝对 HTTP(S)、缺失 host 和畸形 URL，保留合法地址', () {
      final info = _update('cn', const [
        AppDownload(url: '', region: 'cn'),
        AppDownload(url: '/app.apk', region: 'cn'),
        AppDownload(url: '//mirror.example/app', region: 'cn'),
        AppDownload(url: 'https:///app.apk', region: 'cn'),
        AppDownload(url: 'file:///tmp/app.apk', region: 'cn'),
        AppDownload(url: 'javascript:alert(1)', region: 'cn'),
        AppDownload(url: 'https://[broken/app', region: 'cn'),
        AppDownload(url: 'https://bad host.example/app', region: 'cn'),
        AppDownload(url: 'https://bad%20host.example/app', region: 'cn'),
        AppDownload(url: 'https://bad%0ahost.example/app', region: 'cn'),
        AppDownload(url: 'http://mirror.example:8080/app', region: 'overseas'),
        AppDownload(
          url: '  https://mirror.example/app?token=a%2Fb  ',
          region: 'cn',
        ),
        AppDownload(url: 'https://[::1]/app', region: 'overseas'),
      ]);

      expect(xbSortedUpdateUrls(info), [
        'https://mirror.example/app?token=a%2Fb',
        'http://mirror.example:8080/app',
        'https://[::1]/app',
      ]);
    });

    test('不重排或改写原清单，也不去重后端候选', () {
      final original = List<AppDownload>.of(downloads)..add(downloads.first);
      final snapshot = List<AppDownload>.of(original);
      final info = _update('overseas', original);

      final urls = xbSortedUpdateUrls(info);

      expect(info.downloads, orderedEquals(snapshot));
      expect(urls.where((url) => url == downloads.first.url), hasLength(2));
      urls.clear();
      expect(info.downloads, orderedEquals(snapshot));
    });

    test('空清单与全部非法候选返回空列表', () {
      expect(xbSortedUpdateUrls(_update('cn', const [])), isEmpty);
      expect(
        xbSortedUpdateUrls(
          _update('unknown', const [
            AppDownload(url: 'mailto:user@example.com', region: 'unknown'),
          ]),
        ),
        isEmpty,
      );
    });
  });

  group('xbOpenUpdateDownload', () {
    test('先打开地区优先的合法源，首次成功后不继续', () async {
      final opened = <Uri>[];
      final result = await xbOpenUpdateDownload(
        _update('overseas', downloads),
        open: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      expect(result, isTrue);
      expect(opened, [Uri.parse('https://overseas-one.example/app')]);
    });

    test('返回 false 后按排序尝试下一源', () async {
      final opened = <Uri>[];
      final result = await xbOpenUpdateDownload(
        _update('overseas', downloads),
        open: (uri) async {
          opened.add(uri);
          return opened.length == 2;
        },
      );

      expect(result, isTrue);
      expect(opened, [
        Uri.parse('https://overseas-one.example/app'),
        Uri.parse('https://overseas-two.example/app'),
      ]);
    });

    test('抛异常后继续下一源，成功后停止', () async {
      final opened = <Uri>[];
      final result = await xbOpenUpdateDownload(
        _update('cn', downloads),
        open: (uri) async {
          opened.add(uri);
          if (opened.length == 1) throw StateError('launcher unavailable');
          return true;
        },
      );

      expect(result, isTrue);
      expect(opened, [
        Uri.parse('https://cn-one.example/app'),
        Uri.parse('https://cn-two.example/app'),
      ]);
    });

    test('所有源均返回 false 或抛错时返回 false', () async {
      final opened = <Uri>[];
      final result = await xbOpenUpdateDownload(
        _update('unknown', const [
          AppDownload(url: 'https://one.example/app', region: 'cn'),
          AppDownload(url: 'https://two.example/app', region: 'overseas'),
        ]),
        open: (uri) async {
          opened.add(uri);
          if (opened.length == 2) throw StateError('launcher unavailable');
          return false;
        },
      );

      expect(result, isFalse);
      expect(opened, [
        Uri.parse('https://one.example/app'),
        Uri.parse('https://two.example/app'),
      ]);
    });

    test('跳过非法源，不将非 HTTP(S) URI 交给浏览器', () async {
      final opened = <Uri>[];
      final result = await xbOpenUpdateDownload(
        _update('cn', const [
          AppDownload(url: 'javascript:alert(1)', region: 'cn'),
          AppDownload(url: '/relative/app', region: 'cn'),
          AppDownload(url: 'https://valid.example/app', region: 'overseas'),
        ]),
        open: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      expect(result, isTrue);
      expect(opened, [Uri.parse('https://valid.example/app')]);
    });

    test('没有合法候选时返回 false，不调用外部入口', () async {
      var attempts = 0;
      final result = await xbOpenUpdateDownload(
        _update('cn', const [AppDownload(url: '', region: 'cn')]),
        open: (_) async {
          attempts++;
          return true;
        },
      );

      expect(result, isFalse);
      expect(attempts, 0);
    });
  });
}
