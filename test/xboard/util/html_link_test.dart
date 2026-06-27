/// resolveHtmlLink 契约测试（conventions §11：框架含故障/边界路径）。
///
/// 覆盖后端正文真实形态：绝对 URL / 相对路径（downloads/x.apk）/ 根相对·SPA（/#/dashboard）
/// / mailto / 页内锚点 / javascript / 无 base / 非法 base。

import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/util/html_link.dart';

void main() {
  group('resolveHtmlLink — 绝对方案', () {
    test('https 原样', () {
      expect(resolveHtmlLink('https://github.com/x/releases').toString(),
          'https://github.com/x/releases');
    });
    test('http 原样', () {
      expect(resolveHtmlLink('http://a.com/p').toString(), 'http://a.com/p');
    });
    test('mailto / tel 原样', () {
      expect(resolveHtmlLink('mailto:a@b.com').toString(), 'mailto:a@b.com');
      expect(resolveHtmlLink('tel:10086').toString(), 'tel:10086');
    });
    test('其它 scheme（data:）→ null', () {
      expect(resolveHtmlLink('data:text/html,x'), isNull);
    });
  });

  group('resolveHtmlLink — 相对链接（需 base）', () {
    const base = 'https://tv.bilibilicontent.store';
    test('相对路径 downloads/x.apk → 站点根解析（id=22 真实用例）', () {
      expect(
        resolveHtmlLink('downloads/FlClash-0.8.92-android-arm64-v8a.apk',
                base: base)
            .toString(),
        'https://tv.bilibilicontent.store/downloads/FlClash-0.8.92-android-arm64-v8a.apk',
      );
    });
    test('根相对 / SPA 路由 /#/dashboard（id=21 真实用例）', () {
      expect(resolveHtmlLink('/#/dashboard', base: base).toString(),
          'https://tv.bilibilicontent.store/#/dashboard');
    });
    test('base 带路径时相对解析替换末段', () {
      expect(resolveHtmlLink('x.apk', base: 'https://h.com/omo').toString(),
          'https://h.com/x.apk');
    });
    test('相对但无 base → null（无从解析）', () {
      expect(resolveHtmlLink('downloads/x.apk'), isNull);
    });
    test('相对但 base 非 http(s) → null', () {
      expect(resolveHtmlLink('x.apk', base: 'ftp://h.com'), isNull);
      expect(resolveHtmlLink('x.apk', base: 'not a url'), isNull);
    });
  });

  group('resolveHtmlLink — 忽略项 → null', () {
    test('空 / null / 空白', () {
      expect(resolveHtmlLink(null), isNull);
      expect(resolveHtmlLink(''), isNull);
      expect(resolveHtmlLink('   '), isNull);
    });
    test('页内锚点 # / #sec', () {
      expect(resolveHtmlLink('#'), isNull);
      expect(resolveHtmlLink('#section', base: 'https://h.com'), isNull);
    });
    test('javascript: / about:blank', () {
      expect(resolveHtmlLink('javascript:void(0)'), isNull);
      expect(resolveHtmlLink('JavaScript:alert(1)'), isNull);
      expect(resolveHtmlLink('about:blank'), isNull);
    });
  });
}
