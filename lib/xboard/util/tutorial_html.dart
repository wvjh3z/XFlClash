/// Authenticated Knowledge HTML prepared for the embedded tutorial reader.
///
/// Keeps the author's document and CSS, resolves resources before loadData
/// (Windows ignores its baseUrl), and replaces article JavaScript with a small
/// reader bridge. Neither API tokens nor a website login session belong here.
library;

import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// Preserves full documents and also accepts editor HTML fragments.
///
/// [resourceBase] is the content's resource source, not automatically the
/// current API mirror. An authored, valid HTTP(S) `<base>` takes precedence;
/// it is consumed and removed so fragment links stay in this reading page.
/// The only JavaScript handlers are tutorialCopy(value) and tutorialLink(url).
/// They return success booleans; feedback and image preview stay in the WebView.
String buildTutorialHtml(
  String body, {
  required Uri resourceBase,
  required bool isDark,
}) {
  if (!_isHttp(resourceBase)) {
    throw ArgumentError('resourceBase must be an HTTP(S) resource source');
  }
  final document = html.parse(body);
  final base = _resourceBase(document, resourceBase);
  final authoredColors =
      document.querySelector('style, link[rel="stylesheet"]') != null ||
      document
          .querySelectorAll('[style]')
          .any(
            (element) => RegExp(
              r'(?:^|;)\s*(?:color|background(?:-color)?)\s*:',
              caseSensitive: false,
            ).hasMatch(element.attributes['style'] ?? ''),
          );

  for (final element in document.querySelectorAll('*').toList()) {
    final tag = element.localName ?? '';
    if (const {
      'script',
      'base',
      'object',
      'embed',
      'applet',
      'template',
      'foreignObject',
    }.contains(tag)) {
      element.remove();
      continue;
    }
    if (tag == 'iframe' || tag == 'frame') {
      final source = _resolveResource(element.attributes['src'], base);
      if (source != null) {
        final link = Element.tag('a')
          ..attributes['href'] = source
          ..attributes['rel'] = 'noopener noreferrer'
          ..text = '查看嵌入内容';
        element.replaceWith(link);
      } else {
        element.remove();
      }
      continue;
    }
    if (tag == 'meta' &&
        (element.attributes.containsKey('http-equiv') ||
            element.attributes.containsKey('charset') ||
            const {
              'viewport',
              'referrer',
            }.contains(element.attributes['name']?.toLowerCase()))) {
      element.remove();
      continue;
    }
    if (tag == 'link' &&
        !const {
          'stylesheet',
          'icon',
        }.contains(element.attributes['rel']?.toLowerCase())) {
      element.remove();
      continue;
    }

    final action =
        element.attributes['data-original-onclick'] ??
        element.attributes['onclick'];
    for (final key in element.attributes.keys.toList()) {
      final name = key.toString().toLowerCase();
      if (name.startsWith('on') ||
          name.startsWith('data-xb-') ||
          name == 'data-original-onclick' ||
          const {
            'srcdoc',
            'nonce',
            'action',
            'formaction',
            'ping',
          }.contains(name)) {
        element.attributes.remove(key);
      }
    }
    // Known jump(id) means an in-app Knowledge ID even when an authored base
    // points images/styles to a different source.
    _adaptAction(element, action, resourceBase);
    if (tag == 'button') element.attributes['type'] = 'button';

    for (final key in element.attributes.keys.toList()) {
      final name = key.toString().toLowerCase();
      final value = element.attributes[key]!;
      if (name == 'href' || name == 'xlink:href') {
        final link = tag == 'a' || tag == 'area'
            ? _resolveLink(value, base)
            : _resolveResource(value, base, allowFragment: true);
        if (link == null) {
          element.attributes.remove(key);
        } else {
          element.attributes[key] = link;
        }
      } else if (const {'src', 'poster', 'background'}.contains(name)) {
        final resource = _resolveResource(value, base, allowData: true);
        if (resource == null) {
          element.attributes.remove(key);
        } else {
          element.attributes[key] = resource;
        }
      } else if (name == 'srcset') {
        final resources = _resolveSrcset(value, base);
        if (resources.isEmpty) {
          element.attributes.remove(key);
        } else {
          element.attributes[key] = resources;
        }
      } else if (name == 'style') {
        element.attributes[key] = _resolveCss(value, base);
      }
    }
    if (tag == 'style') element.text = _resolveCss(element.text, base);
    if (tag == 'img') element.attributes.putIfAbsent('loading', () => 'lazy');
    if (tag == 'a' || tag == 'area') {
      element.attributes['rel'] = 'noopener noreferrer';
      element.attributes.remove('target');
    }
  }

  final head = document.head!;
  final random = Random.secure();
  final nonce = base64Url.encode(
    List<int>.generate(18, (_) => random.nextInt(256)),
  );
  final defaults = Element.tag('style')
    ..attributes['data-xb-reader'] = 'defaults'
    ..text = _defaultCss(isDark && !authoredColors);
  final charset = Element.tag('meta')..attributes['charset'] = 'utf-8';
  final viewport = Element.tag('meta')
    ..attributes['name'] = 'viewport'
    ..attributes['content'] = 'width=device-width, initial-scale=1.0';
  final referrer = Element.tag('meta')
    ..attributes['name'] = 'referrer'
    ..attributes['content'] = 'no-referrer';
  final policy = Element.tag('meta')
    ..attributes['http-equiv'] = 'Content-Security-Policy'
    ..attributes['content'] =
        "default-src 'none'; "
        "script-src 'nonce-$nonce'; style-src 'unsafe-inline' http: https:; "
        'img-src http: https: data:; font-src http: https: data:; '
        "media-src http: https: data:; connect-src 'none'; "
        "frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'";
  // Defaults precede the author's rules, whose color/background pairing wins.
  head.nodes.insertAll(0, [charset, viewport, referrer, policy, defaults]);
  document.body!.append(
    Element.tag('script')
      ..attributes['nonce'] = nonce
      ..attributes['data-xb-reader'] = 'bridge'
      ..text = _readerScript,
  );
  document.documentElement!.attributes.putIfAbsent('lang', () => 'zh-CN');
  return '<!DOCTYPE html>\n${document.documentElement!.outerHtml}';
}

Uri _resourceBase(Document document, Uri fallback) {
  for (final element in document.querySelectorAll('base[href]')) {
    final raw = _cleanUrl(element.attributes['href'] ?? '');
    final uri = Uri.tryParse(raw);
    if (raw.isNotEmpty && uri != null) {
      final resolved = fallback.resolveUri(uri);
      if (_isHttp(resolved)) return resolved.replace(fragment: '');
    }
  }
  return fallback.replace(fragment: '');
}

bool _isHttp(Uri uri) =>
    (uri.isScheme('https') || uri.isScheme('http')) &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

String _cleanUrl(String raw) =>
    raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();

String? _resolveLink(String? raw, Uri base) {
  final value = _cleanUrl(raw ?? '');
  if (value.isEmpty) return null;
  // Hash-router links are site navigation; ordinary hashes are local anchors.
  if (value.startsWith('#') && !value.startsWith('#/')) return value;
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.isScheme('mailto') || uri.isScheme('tel')) return uri.toString();
  final resolved = base.resolveUri(uri);
  return _isHttp(resolved) ? resolved.toString() : null;
}

String? _resolveResource(
  String? raw,
  Uri base, {
  bool allowData = false,
  bool allowFragment = false,
}) {
  final value = _cleanUrl(raw ?? '');
  if (value.isEmpty) return null;
  if (allowFragment && value.startsWith('#')) return value;
  if (allowData &&
      RegExp(
        r'^data:(?:image/(?:png|jpe?g|gif|webp|avif|bmp)|font/[\w.+-]+|'
        r'application/(?:font-woff|x-font-[\w.+-]+)|(?:audio|video)/[\w.+-]+)[;,]',
        caseSensitive: false,
      ).hasMatch(value)) {
    return value;
  }
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final resolved = base.resolveUri(uri);
  return _isHttp(resolved) ? resolved.toString() : null;
}

String _resolveSrcset(String value, Uri base) {
  final candidates = <String>[];
  var index = 0;
  while (index < value.length) {
    while (index < value.length &&
        (value[index] == ',' || _isSpace(value[index]))) {
      index++;
    }
    final start = index;
    while (index < value.length && !_isSpace(value[index])) {
      index++;
    }
    var url = value.substring(start, index);
    if (url.isEmpty) break;
    final endedWithComma = url.endsWith(',');
    while (url.endsWith(',')) {
      url = url.substring(0, url.length - 1);
    }
    var descriptor = '';
    if (!endedWithComma) {
      final descriptorStart = index;
      while (index < value.length && value[index] != ',') {
        index++;
      }
      descriptor = value.substring(descriptorStart, index).trim();
    }
    final resource = _resolveResource(url, base, allowData: true);
    if (resource != null) {
      candidates.add('$resource${descriptor.isEmpty ? '' : ' $descriptor'}');
    }
  }
  return candidates.join(', ');
}

bool _isSpace(String value) => RegExp(r'\s').hasMatch(value);

String _resolveCss(String css, Uri base) {
  var result = css.replaceAllMapped(
    RegExp(
      r'''url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)''',
      caseSensitive: false,
    ),
    (match) {
      final value = _decodeCssEscapes(
        match.group(1) ?? match.group(2) ?? match.group(3) ?? '',
      );
      final resource =
          _resolveResource(
            value.trim(),
            base,
            allowData: true,
            allowFragment: true,
          ) ??
          'about:blank';
      return 'url("${_cssString(resource)}")';
    },
  );
  result = result.replaceAllMapped(
    RegExp(r'''@import\s+(?:"([^"]*)"|'([^']*)')''', caseSensitive: false),
    (match) {
      final resource =
          _resolveResource(
            _decodeCssEscapes(match.group(1) ?? match.group(2) ?? ''),
            base,
          ) ??
          'about:blank';
      return '@import url("${_cssString(resource)}")';
    },
  );
  return result;
}

String _decodeCssEscapes(String value) => value.replaceAllMapped(
  RegExp(r'\\(?:([0-9a-fA-F]{1,6})\s?|([^\r\n]))'),
  (match) {
    if (match.group(1) == null) return match.group(2)!;
    final code = int.parse(match.group(1)!, radix: 16);
    return code == 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)
        ? '\uFFFD'
        : String.fromCharCode(code);
  },
);

String _cssString(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

void _adaptAction(Element element, String? action, Uri base) {
  if (action == null) return;
  final copy = RegExp(
    r'''^\s*(?:return\s+)?copy\s*\(\s*((?:"(?:\\.|[^"\\])*")|(?:'(?:\\.|[^'\\])*'))\s*\)\s*;?\s*$''',
    caseSensitive: false,
  ).firstMatch(action);
  if (copy != null) {
    final value = _decodeStringLiteral(copy.group(1)!);
    if (value != null && value.isNotEmpty) {
      element.attributes['data-xb-copy'] = value;
    }
    return;
  }
  final jump = RegExp(
    r'^\s*(?:return\s+)?jump\s*\(\s*(\d+)\s*\)\s*;?\s*$',
    caseSensitive: false,
  ).firstMatch(action);
  final id = int.tryParse(jump?.group(1) ?? '');
  if (id != null && id > 0) {
    element.attributes['data-xb-jump'] = base
        .resolve('/')
        .replace(fragment: '/docs/$id')
        .toString();
  }
}

// Decode one string argument; never execute the original event handler.
String? _decodeStringLiteral(String literal) {
  final input = literal.substring(1, literal.length - 1);
  final result = StringBuffer();
  for (var index = 0; index < input.length; index++) {
    var character = input[index];
    if (character != '\\') {
      result.write(character);
      continue;
    }
    if (++index >= input.length) return null;
    character = input[index];
    const escapes = {
      'n': '\n',
      'r': '\r',
      't': '\t',
      'b': '\b',
      'f': '\f',
      'v': '\v',
      '0': '\x00',
    };
    if (character == 'x' || character == 'u') {
      final length = character == 'x' ? 2 : 4;
      if (index + length >= input.length) return null;
      final code = int.tryParse(
        input.substring(index + 1, index + length + 1),
        radix: 16,
      );
      if (code == null) return null;
      result.writeCharCode(code);
      index += length;
    } else if (character != '\n' && character != '\r') {
      result.write(escapes[character] ?? character);
    }
  }
  return result.toString();
}

String _defaultCss(bool dark) =>
    '''
html { color-scheme: ${dark ? 'dark' : 'light'}; }
body { margin: 0; padding: 20px; box-sizing: border-box;
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size: 15px; line-height: 1.75; overflow-wrap: anywhere;
  background: ${dark ? '#111318' : '#ffffff'};
  color: ${dark ? '#e5e7eb' : '#202124'}; }
img, video { max-width: 100%; height: auto; }
img { cursor: zoom-in; }
pre { overflow-x: auto; overflow-wrap: normal; }
table { display: block; max-width: 100%; overflow-x: auto; }
a { color: ${dark ? '#8ab4f8' : '#1967d2'}; }
button, [data-xb-copy], [data-xb-jump] { cursor: pointer; }
''';

// Fixed code only: article text lives in escaped DOM attributes, never in JS.
const _readerScript = r'''
(() => {
  'use strict';
  const ready = new Promise(resolve => {
    window.addEventListener('flutterInAppWebViewPlatformReady', resolve, {once: true});
  });
  async function invoke(handler, value) {
    if (!window.flutter_inappwebview ||
        typeof window.flutter_inappwebview.callHandler !== 'function') {
      await Promise.race([ready, new Promise(resolve => setTimeout(resolve, 2000))]);
    }
    if (!window.flutter_inappwebview ||
        typeof window.flutter_inappwebview.callHandler !== 'function') return false;
    try {
      return await window.flutter_inappwebview.callHandler(handler, value);
    } catch (_) {
      return false;
    }
  }
  function closest(event, selector) {
    const element = event.target && event.target.nodeType === 1
      ? event.target : event.target && event.target.parentElement;
    return element && element.closest(selector);
  }
  function consume(event) {
    event.preventDefault();
    event.stopPropagation();
  }
  let toastHost;
  let toastTimeout;
  function toast(message) {
    if (toastHost) toastHost.remove();
    clearTimeout(toastTimeout);
    toastHost = document.createElement('div');
    toastHost.style.cssText = 'position:fixed!important;bottom:24px!important;left:50%!important;transform:translateX(-50%)!important;z-index:2147483647!important;pointer-events:none!important;';
    const shadow = toastHost.attachShadow({mode: 'closed'});
    const text = document.createElement('div');
    text.style.cssText = 'padding:10px 18px;border-radius:8px;background:#323232;color:white;font:14px system-ui,sans-serif;box-shadow:0 2px 10px #0004;';
    text.setAttribute('role', 'status');
    text.textContent = message;
    shadow.appendChild(text);
    document.body.appendChild(toastHost);
    toastTimeout = setTimeout(() => { toastHost.remove(); toastHost = null; }, 1800);
  }
  async function openLink(url) {
    if (!await invoke('tutorialLink', url)) toast('无法打开链接');
  }
  function showImage(url) {
    // Preview reuses this reader's browser resource loading and interactions,
    // including raster data images, without a second Flutter image request.
    const host = document.createElement('div');
    host.style.cssText = 'position:fixed!important;inset:0!important;z-index:2147483647!important;';
    const shadow = host.attachShadow({mode: 'closed'});
    shadow.innerHTML = `<style>
      :host { font: 14px system-ui, sans-serif; }
      .viewer { position:absolute;inset:0;background:rgba(0,0,0,.94);color:white; }
      .tools { height:56px;display:flex;justify-content:flex-end;align-items:center;gap:8px;padding:0 12px; }
      button { border:1px solid #666;border-radius:6px;background:#202124;color:white;padding:6px 12px;cursor:pointer; }
      .stage { height:calc(100% - 56px);overflow:auto;display:flex;justify-content:center;align-items:center; }
      img { display:block;max-width:100%;max-height:100%;object-fit:contain;flex-shrink:0; }
    </style><div class="viewer"><div class="tools">
      <button type="button" data-zoom="out" aria-label="缩小图片">−</button>
      <button type="button" data-zoom="in" aria-label="放大图片">＋</button>
      <button type="button" data-close aria-label="关闭图片预览">关闭</button>
    </div><div class="stage"><img alt="教程图片预览"></div></div>`;
    const image = shadow.querySelector('img');
    const stage = shadow.querySelector('.stage');
    let scale = 1;
    let fittedWidth = 0;
    function resize(factor) {
      if (!image.complete || !image.naturalWidth) return;
      if (!fittedWidth) fittedWidth = image.getBoundingClientRect().width;
      scale = Math.max(.5, Math.min(8, scale * factor));
      image.style.maxWidth = 'none';
      image.style.maxHeight = 'none';
      image.style.width = `${fittedWidth * scale}px`;
      stage.style.justifyContent = scale > 1 ? 'flex-start' : 'center';
      stage.style.alignItems = scale > 1 ? 'flex-start' : 'center';
    }
    const previousFocus = document.activeElement;
    function close() {
      document.removeEventListener('keydown', keydown, true);
      host.remove();
      if (previousFocus && typeof previousFocus.focus === 'function') previousFocus.focus();
    }
    function keydown(event) {
      if (event.key === 'Escape') { consume(event); close(); }
    }
    shadow.querySelector('[data-close]').addEventListener('click', close);
    shadow.querySelector('[data-zoom="in"]').addEventListener('click', () => resize(1.5));
    shadow.querySelector('[data-zoom="out"]').addEventListener('click', () => resize(1 / 1.5));
    stage.addEventListener('click', event => { if (event.target === stage) close(); });
    image.addEventListener('dblclick', () => resize(scale > 1 ? 1 / scale : 2));
    image.src = url;
    document.body.appendChild(host);
    document.addEventListener('keydown', keydown, true);
    shadow.querySelector('[data-close]').focus();
  }
  document.addEventListener('submit', event => consume(event), true);
  document.addEventListener('click', async event => {
    const copy = closest(event, '[data-xb-copy]');
    if (copy) {
      consume(event);
      if (copy.dataset.xbBusy === '1') return;
      copy.dataset.xbBusy = '1';
      try {
        const success = await invoke('tutorialCopy', copy.getAttribute('data-xb-copy'));
        toast(success ? '已复制' : '复制失败');
      }
      finally { delete copy.dataset.xbBusy; }
      return;
    }
    const jump = closest(event, '[data-xb-jump]');
    if (jump) {
      consume(event);
      await openLink(jump.getAttribute('data-xb-jump'));
      return;
    }
    const link = closest(event, 'a[href], area[href]');
    if (link) {
      consume(event);
      const href = link.getAttribute('href');
      if (href && href[0] === '#' && !href.startsWith('#/')) {
        let id = href.slice(1);
        try { id = decodeURIComponent(id); } catch (_) {}
        const target = document.getElementById(id) || document.getElementsByName(id)[0];
        if (target) target.scrollIntoView({behavior: 'smooth', block: 'start'});
        else if (!id) window.scrollTo({top: 0, behavior: 'smooth'});
      } else if (href) {
        await openLink(href);
      }
      return;
    }
    const image = closest(event, 'img');
    const imageUrl = image && (image.currentSrc || image.getAttribute('src'));
    if (imageUrl && !String(window.getSelection() || '')) {
      consume(event);
      showImage(imageUrl);
    }
  }, true);
  console.info('__xb_tutorial_ready__');
})();
''';
