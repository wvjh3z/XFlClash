/// Platform boundary for Crisp 3.0.0. Keep plugin-specific calls out of UI/session logic.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crisp_chat/crisp_chat.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class CrispChatDriver {
  Stream<void> get sessionLoaded;
  Future<void> open(CrispConfig config);
  Future<String?> sessionId();
  Future<void> setString(String key, String value);
  Future<void> reset(String websiteId);
}

class NativeCrispChatDriver implements CrispChatDriver {
  static const _channel = MethodChannel('flutter_crisp_chat');

  late final StreamController<void> _events = StreamController<void>.broadcast(
    onListen: () {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onCrispEvent' &&
            call.arguments is Map &&
            (call.arguments as Map)['type'] == 'sessionLoaded') {
          _events.add(null);
        }
      });
      unawaited(
        _channel
            .invokeMethod<void>('registerCrispEventListener')
            .catchError((Object _) {}),
      );
    },
    onCancel: () {
      unawaited(
        _channel
            .invokeMethod<void>('unregisterCrispEventListener')
            .catchError((Object _) {}),
      );
    },
  );

  @override
  Stream<void> get sessionLoaded => _events.stream;

  @override
  Future<void> open(CrispConfig config) =>
      _channel.invokeMethod<void>('openCrispChat', config.toJson());

  @override
  Future<String?> sessionId() async {
    try {
      return await _channel.invokeMethod<String>('getSessionIdentifier');
    } on PlatformException catch (error) {
      if (error.code == 'NO_SESSION') return null;
      rethrow;
    }
  }

  @override
  Future<void> setString(String key, String value) => _channel
      .invokeMethod<void>('setSessionString', {'key': key, 'value': value});

  @override
  Future<void> reset(String websiteId) =>
      _channel.invokeMethod<void>('resetCrispChatSession');
}

/// Windows/macOS/Linux retain the existing WebView transport. Unlike the plugin's
/// desktop wrapper, writes are awaited, closed handles are cleared and no operator
/// dashboard URL is opened as a visitor fallback.
class DesktopCrispChatDriver implements CrispChatDriver {
  DesktopCrispChatDriver({
    Future<bool> Function()? available,
    Future<Webview> Function()? create,
  }) : _available = available ?? WebviewWindow.isWebviewAvailable,
       _create =
           create ??
           (() => WebviewWindow.create(
             configuration: const CreateConfiguration(
               title: '在线客服',
               titleBarTopPadding: 0,
               windowWidth: 420,
               windowHeight: 720,
             ),
           ));
  final Future<bool> Function() _available;
  final Future<Webview> Function() _create;
  Webview? _window;
  Directory? _directory;
  String? _pendingResetKey;

  @override
  Stream<void> get sessionLoaded => const Stream.empty();

  @override
  Future<void> open(CrispConfig config) async {
    if (!await _available()) {
      throw StateError('Customer support WebView unavailable');
    }
    await _close();
    final prefs = await SharedPreferences.getInstance();
    final resetKey = 'xb_crisp_desktop_reset_${config.websiteID}';
    final pendingReset = prefs.getBool(resetKey) ?? false;
    _pendingResetKey = pendingReset ? resetKey : null;
    final directory = await Directory.systemTemp.createTemp('xfl_crisp_');
    _directory = directory;
    try {
      final html = desktopCrispHtml(
        config.websiteID,
        config.sessionSegment,
        pendingReset,
      );
      final file = File('${directory.path}/index.html');
      await file.writeAsString(html);
      final window = await _create();
      _window = window;
      unawaited(
        window.onClose.then((_) async {
          if (identical(_window, window)) _window = null;
          try {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          } catch (_) {}
        }),
      );
      window.launch(file.uri.toString());
    } catch (_) {
      await _close();
      rethrow;
    }
  }

  @override
  Future<String?> sessionId() async {
    final window = _window;
    if (window == null) return null;
    try {
      final value = _desktopString(
        await window.evaluateJavaScript(
          r'(function(){return window.__xbCrispReady ? String(window.__xbCrispSession || "") : "";})();',
        ),
      );
      if (value == null || value.isEmpty || value == 'null') return null;
      final key = _pendingResetKey;
      if (key != null) {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.remove(key)) {
          throw StateError('Session reset acknowledgement failed');
        }
        _pendingResetKey = null;
      }
      return value;
    } on PlatformException {
      return null; // Native view may still be starting or already closed.
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    final window = _window;
    if (window == null) throw StateError('Customer support window closed');
    // Explicit acknowledgement reports JS execution, not remote persistence.
    final command =
        '\$crisp.push(["set","session:data",[[[${jsonEncode(key)},${jsonEncode(value)}]]]]);';
    final identity = key == 'Email'
        ? '\$crisp.push(["set","user:email",[${jsonEncode(value)}]]);'
              '\$crisp.push(["set","user:nickname",[${jsonEncode(value.split('@').first)}]]);'
        : '';
    final result = await window.evaluateJavaScript(
      '(function(){try{$command$identity return "ok";}catch(e){return "failed";}})();',
    );
    if (_desktopString(result) != 'ok') {
      throw StateError('Customer support data not accepted');
    }
  }

  @override
  Future<void> reset(String websiteId) async {
    await _close();
    // Persist pending reset: a closed/offline WebView cannot run session:reset.
    // Next open hides the chat until reset produces a new session:loaded event.
    if (websiteId.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool('xb_crisp_desktop_reset_$websiteId', true)) {
        throw StateError('Customer support reset was not persisted');
      }
    }
  }

  Future<void> _close() async {
    final window = _window;
    _window = null;
    window?.close();
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

/// No account data is placed in the temporary HTML. Escape script delimiters even
/// though website ID and segment normally contain only simple configuration text.
String desktopCrispHtml(String websiteId, String? segment, bool reset) {
  String js(String value) => jsonEncode(value).replaceAll('<', r'\u003c');
  return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:14px system-ui;padding:24px;color:#555}</style></head>
<body><p id="status">正在加载客服，请稍候…</p><script>
window.\$crisp=[];window.CRISP_WEBSITE_ID=${js(websiteId)};
window.__xbCrispReady=false;var resetPending=${reset ? 'true' : 'false'};
\$crisp.push(["do","chat:hide"]);
\$crisp.push(["on","session:loaded",function(id){
  if(resetPending){resetPending=false;\$crisp.push(["do","session:reset"]);return;}
  window.__xbCrispSession=id;window.__xbCrispReady=true;
  document.getElementById("status").textContent="";
  ${segment == null ? '' : '\$crisp.push(["set","session:segments",[[${js(segment)}]]]);'}
  \$crisp.push(["do","chat:show"]);\$crisp.push(["do","chat:open"]);
}]);
setTimeout(function(){if(!window.__xbCrispReady){document.getElementById("status").textContent="客服加载较慢，请检查网络，关闭窗口后重试。";}},15000);
</script><script src="https://client.crisp.chat/l.js" async></script></body></html>''';
}

/// WebView2/WebKit return JSON-encoded scalars; WKWebView returns plain strings.
String? _desktopString(String? value) {
  if (value == null) return null;
  try {
    final decoded = jsonDecode(value);
    if (decoded == null || decoded is String) return decoded as String?;
  } on FormatException {
    // A plain macOS result is not necessarily JSON.
  }
  return value;
}
