import 'package:fl_clash/xboard/util/tutorial_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

void main() {
  final source = Uri.parse('https://content.example/tutorials/');

  Document prepare(String input, {bool dark = false, Uri? base}) => html.parse(
    buildTutorialHtml(input, resourceBase: base ?? source, isDark: dark),
  );

  group('tutorial document and theme', () {
    test(
      'keeps authored title, full CSS, responsive rules and only its heading',
      () {
        final document = prepare('''
<!DOCTYPE HTML><HTML lang="en"><HEAD>
<title>原文标题</title><style>
:root { --ink: #123; } body { color: var(--ink); background: #fff; }
.steps { display: grid; grid-template-columns: 1fr 1fr; }
@media (max-width: 600px) { .steps { display: block; } }
</style></HEAD><BODY class="article"><h1>原文标题</h1><p>教程正文</p></BODY></HTML>
''', dark: true);
        expect(document.querySelector('title')!.text, '原文标题');
        expect(document.querySelectorAll('h1'), hasLength(1));
        expect(document.body!.classes, contains('article'));
        expect(document.documentElement!.attributes['lang'], 'en');
        final authorCss = document.querySelectorAll('style').last.text;
        expect(authorCss, contains('--ink: #123'));
        expect(authorCss, contains('color: var(--ink)'));
        expect(authorCss, contains('display: grid'));
        expect(authorCss, contains('@media (max-width: 600px)'));
      },
    );

    test(
      'normalizes charset and responsive viewport without disabling zoom',
      () {
        final document = prepare('''
<html><head><meta charset="latin1"><meta name="viewport" content="width=1200, maximum-scale=1">
</head><body><p>中文</p></body></html>
''');
        expect(document.querySelectorAll('meta[charset]'), hasLength(1));
        expect(
          document.querySelector('meta[charset]')!.attributes['charset'],
          'utf-8',
        );
        expect(
          document.querySelectorAll('meta[name="viewport"]'),
          hasLength(1),
        );
        expect(
          document
              .querySelector('meta[name="viewport"]')!
              .attributes['content'],
          'width=device-width, initial-scale=1.0',
        );
        expect(document.body!.text, contains('中文'));
      },
    );

    test('unstyled editor fragments follow the selected theme', () {
      final light = prepare('<p>plain</p>');
      final dark = prepare('<p>plain</p>', dark: true);
      expect(
        light.querySelector('style[data-xb-reader="defaults"]')!.text,
        contains('background: #ffffff'),
      );
      expect(
        dark.querySelector('style[data-xb-reader="defaults"]')!.text,
        contains('background: #111318'),
      );
      expect(
        dark.querySelector('style[data-xb-reader="defaults"]')!.text,
        contains('color: #e5e7eb'),
      );
    });

    test(
      'authored inline color and background pairing is kept on a light base',
      () {
        final document = prepare(
          '<p style="color:#111827">正文</p>'
          '<aside style="background:#fff3cd;color:#663c00">提示</aside>',
          dark: true,
        );
        expect(
          document.querySelector('p')!.attributes['style'],
          'color:#111827',
        );
        expect(
          document.querySelector('aside')!.attributes['style'],
          'background:#fff3cd;color:#663c00',
        );
        expect(
          document.querySelector('style[data-xb-reader="defaults"]')!.text,
          contains('background: #ffffff'),
        );
      },
    );

    test('does not inject a tutorial title into an HTML fragment', () {
      final document = prepare('<p>只有正文</p>');
      expect(document.querySelectorAll('h1, h2, title'), isEmpty);
      expect(document.querySelector('p')!.text, '只有正文');
    });
  });

  group('resource sources independent of WebView baseUrl', () {
    test(
      'resolves relative, root-relative and protocol-relative resources',
      () {
        final document = prepare('''
<img id="relative" src="images/step 1.png">
<img id="root" src="/assets/step2.png">
<img id="cdn" src="//cdn.example/step3.png">
<video src="clips/step.mp4" poster="images/cover.jpg"></video>
<a href="downloads/client.apk">下载</a>
''');
        expect(
          document.getElementById('relative')!.attributes['src'],
          'https://content.example/tutorials/images/step%201.png',
        );
        expect(
          document.getElementById('root')!.attributes['src'],
          'https://content.example/assets/step2.png',
        );
        expect(
          document.getElementById('cdn')!.attributes['src'],
          'https://cdn.example/step3.png',
        );
        expect(
          document.querySelector('video')!.attributes['poster'],
          'https://content.example/tutorials/images/cover.jpg',
        );
        expect(
          document.querySelector('video')!.attributes['src'],
          'https://content.example/tutorials/clips/step.mp4',
        );
        expect(
          document.querySelector('a')!.attributes['href'],
          'https://content.example/tutorials/downloads/client.apk',
        );
        expect(document.querySelector('base'), isNull);
      },
    );

    test('consumes an authored base while preserving local anchors', () {
      final document = prepare('''
<head><base href="https://author.example/articles/" target="_blank"></head>
<img src="step.png"><a id="anchor" href="#安装">安装</a><h2 id="安装">安装</h2>
<a id="route" href="#/docs/7">教程</a>
''');
      expect(
        document.querySelector('img')!.attributes['src'],
        'https://author.example/articles/step.png',
      );
      expect(document.getElementById('anchor')!.attributes['href'], '#安装');
      expect(
        document.getElementById('route')!.attributes['href'],
        'https://author.example/articles/#/docs/7',
      );
      expect(document.querySelector('base'), isNull);
    });

    test('ignores invalid or credential-bearing authored bases', () {
      for (final base in [
        'javascript:alert(1)',
        'file:///tmp/local/',
        'https://user:password@author.example/',
      ]) {
        final document = prepare('<base href="$base"><img src="step.png">');
        expect(
          document.querySelector('img')!.attributes['src'],
          'https://content.example/tutorials/step.png',
        );
        expect(document.querySelector('base'), isNull);
      }
    });

    test(
      'resolves srcset without splitting a raster data URL at its comma',
      () {
        final document = prepare('''
<picture><source srcset="/wide.png 800w, large.png 1600w">
<img src="small.png" srcset="data:image/png;base64,AAAA 1x, retina.png 2x, javascript:bad 3x"></picture>
''');
        expect(
          document.querySelector('source')!.attributes['srcset'],
          'https://content.example/wide.png 800w, '
          'https://content.example/tutorials/large.png 1600w',
        );
        expect(
          document.querySelector('img')!.attributes['srcset'],
          'data:image/png;base64,AAAA 1x, '
          'https://content.example/tutorials/retina.png 2x',
        );
      },
    );

    test('resolves common CSS url, import and stylesheet href forms', () {
      final document = prepare('''
<head><link rel="stylesheet" href="styles/article.css"><style>
@import "styles/colors.css" screen;
@import url('../fonts/font.css');
.hero { background: url("images/hero.png"); }
.mask { mask-image: url(#symbol); }
</style></head>
<p style="background-image:url('/images/panel.png')">正文</p>
''');
      expect(
        document.querySelector('link')!.attributes['href'],
        'https://content.example/tutorials/styles/article.css',
      );
      final css = document.querySelectorAll('style').last.text;
      expect(
        css,
        contains(
          '@import url("https://content.example/tutorials/styles/colors.css") screen',
        ),
      );
      expect(css, contains('url("https://content.example/fonts/font.css")'));
      expect(
        css,
        contains('url("https://content.example/tutorials/images/hero.png")'),
      );
      expect(css, contains('url("#symbol")'));
      expect(
        document.querySelector('p')!.attributes['style'],
        'background-image:url("https://content.example/images/panel.png")',
      );
    });

    test('decodes CSS escapes before checking the URL scheme', () {
      final document = prepare(r'''
<style>.ok{background:url("images/step\ 1.png")}
.bad{background:url("\6a avascript:alert(1)")}</style>
''');
      final css = document.querySelectorAll('style').last.text;
      expect(
        css,
        contains(
          'url("https://content.example/tutorials/images/step%201.png")',
        ),
      );
      expect(css, contains('url("about:blank")'));
      expect(css, isNot(contains('javascript:')));
    });

    test(
      'accepts HTTP resources without weakening non-network scheme rules',
      () {
        final document = prepare(
          '<img src="/step.png">',
          base: Uri.parse('http://192.0.2.1/'),
        );
        expect(
          document.querySelector('img')!.attributes['src'],
          'http://192.0.2.1/step.png',
        );
        expect(
          () => buildTutorialHtml(
            '<p>body</p>',
            resourceBase: Uri.parse('file:///tmp/'),
            isDark: false,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('controlled interactions', () {
    test(
      'copies full account values without replacing visible masked text',
      () {
        final document = prepare('''
<div class="value">a***@example.test</div>
<button data-original-onclick="copy('actual &amp; &quot;quoted&quot; value')">复制</button>
''');
        final button = document.querySelector('button')!;
        expect(button.attributes['data-xb-copy'], 'actual & "quoted" value');
        expect(button.attributes['data-original-onclick'], isNull);
        expect(button.attributes['onclick'], isNull);
        expect(button.attributes['type'], 'button');
        expect(document.querySelector('.value')!.text, 'a***@example.test');
        expect(button.text, '复制');
        final script = document.querySelector('script')!.text;
        expect(script, contains("invoke('tutorialCopy'"));
        expect(script, isNot(contains('actual & "quoted" value')));
        expect(script, isNot(contains('eval(')));
      },
    );

    test('decodes quoted copy arguments without executing JavaScript', () {
      final document = prepare(r'''
<button data-original-onclick="copy('a\'b\\c\n\u4e2d\x21')">复制</button>
''');
      expect(
        document.querySelector('button')!.attributes['data-xb-copy'],
        "a'b\\c\n中!",
      );
    });

    test(
      'adapts known jump calls while leaving ordinary fragment anchors local',
      () {
        final document = prepare('''
<button onclick="return jump(19);">查看教程</button>
<a href="#section">下一节</a><h2 id="section">下一节</h2>
''');
        expect(
          document.querySelector('button')!.attributes['data-xb-jump'],
          'https://content.example/#/docs/19',
        );
        expect(document.querySelector('a')!.attributes['href'], '#section');
        final script = document.querySelector('script')!.text;
        expect(script, contains('document.getElementById(id)'));
        expect(script, contains("invoke('tutorialLink'"));
      },
    );

    test('keeps known jumps in the app when authored base points to a CDN', () {
      final document = prepare('''
<base href="https://cdn.example/articles/"><button onclick="jump(19)">查看</button>
<img src="step.png">
''');
      expect(
        document.querySelector('button')!.attributes['data-xb-jump'],
        'https://content.example/#/docs/19',
      );
      expect(
        document.querySelector('img')!.attributes['src'],
        'https://cdn.example/articles/step.png',
      );
    });

    test(
      'does not accept extra JavaScript or authored bridge data attributes',
      () {
        final document = prepare('''
<button onclick="copy('safe'); alert('bad')" data-xb-copy="spoof">复制</button>
<button data-original-onclick="jump(-1)" data-xb-jump="https://bad.example/">跳转</button>
''');
        for (final button in document.querySelectorAll('button')) {
          expect(button.attributes['data-xb-copy'], isNull);
          expect(button.attributes['data-xb-jump'], isNull);
          expect(button.attributes['onclick'], isNull);
        }
      },
    );

    test(
      'keeps image preview inside the browser surface without a Dart bridge',
      () {
        final document = prepare('<img src="step.png">');
        final script = document.querySelector('script')!.text;
        expect(script, contains("attachShadow({mode: 'closed'})"));
        expect(script, contains("event.key === 'Escape'"));
        expect(script, contains('image.currentSrc'));
        expect(script, contains('showImage('));
        expect(script, isNot(contains('tutorialImage')));
      },
    );
  });

  group('reading page boundaries', () {
    test('replaces arbitrary scripts, event handlers and meta navigation', () {
      final document = prepare('''
<head><script src="https://bad.example/payload.js"></script>
<meta http-equiv="refresh" content="0;url=https://bad.example">
<meta name="referrer" content="unsafe-url"></head>
<body onload="alert('bad')"><img src="step.png" onerror="alert('bad')">
<script>alert('bad')</script><form action="https://bad.example" onsubmit="alert('bad')">
<button formaction="https://bad.example">提交</button></form></body>
''');
      expect(document.querySelectorAll('script'), hasLength(1));
      expect(document.querySelector('script')!.attributes['src'], isNull);
      expect(
        document.querySelector('script')!.text,
        isNot(contains("alert('bad')")),
      );
      expect(document.querySelector('meta[http-equiv="refresh"]'), isNull);
      expect(document.querySelectorAll('meta[name="referrer"]'), hasLength(1));
      expect(
        document.querySelector('meta[name="referrer"]')!.attributes['content'],
        'no-referrer',
      );
      expect(document.body!.attributes['onload'], isNull);
      expect(document.querySelector('img')!.attributes['onerror'], isNull);
      expect(document.querySelector('form')!.attributes['action'], isNull);
      expect(
        document.querySelector('button')!.attributes['formaction'],
        isNull,
      );
    });

    test('generates a fresh nonce paired with the only executable script', () {
      final first = prepare('<p>body</p>');
      final second = prepare('<p>body</p>');
      final nonce = first.querySelector('script')!.attributes['nonce']!;
      expect(nonce, isNotEmpty);
      expect(second.querySelector('script')!.attributes['nonce'], isNot(nonce));
      final policy = first
          .querySelector('meta[http-equiv="Content-Security-Policy"]')!
          .attributes['content']!;
      expect(policy, contains("script-src 'nonce-$nonce'"));
      expect(policy, contains("connect-src 'none'"));
      expect(policy, contains("frame-src 'none'"));
      expect(policy, isNot(contains("script-src 'unsafe-inline'")));
    });

    test('does not leave executable or local resource URLs in the article', () {
      final document = prepare('''
<a id="js" href="java&#x0a;script:alert(1)">危险链接</a>
<a id="file" href="file:///etc/passwd">本地</a>
<a id="mail" href="mailto:support@example.test">邮件</a>
<a id="phone" href="tel:10086">电话</a>
<img id="html" src="data:text/html;base64,AAAA">
<img id="svg" src="data:image/svg+xml;base64,AAAA">
<img id="png" src="data:image/png;base64,AAAA">
<object data="https://bad.example/"></object><embed src="https://bad.example/">
''');
      expect(document.getElementById('js')!.attributes['href'], isNull);
      expect(document.getElementById('file')!.attributes['href'], isNull);
      expect(
        document.getElementById('mail')!.attributes['href'],
        'mailto:support@example.test',
      );
      expect(document.getElementById('phone')!.attributes['href'], 'tel:10086');
      expect(document.getElementById('html')!.attributes['src'], isNull);
      expect(document.getElementById('svg')!.attributes['src'], isNull);
      expect(
        document.getElementById('png')!.attributes['src'],
        'data:image/png;base64,AAAA',
      );
      expect(document.querySelectorAll('object, embed'), isEmpty);
    });

    test(
      'converts remote frames into explicit links and discards srcdoc frames',
      () {
        final document = prepare('''
<iframe src="https://video.example/watch/7" srcdoc="<script>bad()</script>"></iframe>
<iframe srcdoc="<p>embedded</p>"></iframe>
<iframe src="javascript:bad()"></iframe>
''');
        expect(document.querySelectorAll('iframe'), isEmpty);
        expect(document.querySelectorAll('a'), hasLength(1));
        expect(
          document.querySelector('a')!.attributes['href'],
          'https://video.example/watch/7',
        );
        expect(document.querySelector('a')!.text, '查看嵌入内容');
        expect(
          document.querySelector('script')!.text,
          isNot(contains('bad()')),
        );
      },
    );
  });
}
