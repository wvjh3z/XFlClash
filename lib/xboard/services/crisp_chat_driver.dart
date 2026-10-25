/// Platform boundary for Crisp 3.0.0. Keep plugin-specific calls out of UI/session logic.
library;

import 'package:fl_clash/xboard/storage/brand_paths.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crisp_chat/crisp_chat.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'crisp_navigation.dart';

enum CrispChatFailure {
  notConfigured,
  cancelled,
  webViewUnavailable,
  webView2Unavailable,
  profileUnavailable,
  startupFailed,
  startupTimeout,
  sessionNotReady,
  sessionDataFailed,
  resetFailed,
  windowClosed,
  closeFailed,
}

/// Safe to display or log: platform error text may contain paths or account data.
class CrispChatException implements Exception {
  const CrispChatException(this.failure);

  final CrispChatFailure failure;

  @override
  String toString() => 'CrispChatException(${failure.name})';
}

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

/// Desktop window I/O is bounded and each callback owns one window and HTML
/// directory. A timed-out close remains a barrier until the native close event.
class DesktopCrispChatDriver implements CrispChatDriver {
  DesktopCrispChatDriver({
    Future<void> Function(int)? focusWindow,
    Future<bool> Function(Uri)? openExternal,
    Future<bool> Function()? available,
    Future<Webview> Function(CreateConfiguration)? create,
    Future<Directory> Function()? cacheDirectory,
    Future<SharedPreferences> Function()? preferences,
    bool? isWindowsOverride,
    Duration ioTimeout = const Duration(seconds: 5),
    Duration startupTimeout = const Duration(seconds: 10),
    Duration closeTimeout = const Duration(seconds: 3),
    Duration bootstrapPollInterval = const Duration(milliseconds: 100),
  }) : _focusWindow =
           focusWindow ??
           ((handle) => const MethodChannel(
             'window',
           ).invokeMethod<void>('focusBorrowedWindow', {'handle': handle})),
       _openExternal =
           openExternal ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _available = available ?? WebviewWindow.isWebviewAvailable,
       _create =
           create ??
           ((configuration) =>
               WebviewWindow.create(configuration: configuration)),
       _cacheDirectory = cacheDirectory ?? brandCacheDirectory,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _isWindows = isWindowsOverride ?? Platform.isWindows,
       _ioTimeout = ioTimeout,
       _startupTimeout = startupTimeout,
       _closeTimeout = closeTimeout,
       _bootstrapPollInterval = bootstrapPollInterval;

  final Future<void> Function(int) _focusWindow;
  final Future<bool> Function(Uri) _openExternal;
  final Future<bool> Function() _available;
  final Future<Webview> Function(CreateConfiguration) _create;
  final Future<Directory> Function() _cacheDirectory;
  final Future<SharedPreferences> Function() _preferences;
  final bool _isWindows;
  final Duration _ioTimeout;
  final Duration _startupTimeout;
  final Duration _closeTimeout;
  final Duration _bootstrapPollInterval;
  final Set<_DesktopCrispWindow> _windows = {};
  _DesktopCrispWindow? _active;
  int _generation = 0;
  Future<void> _resetStorageQueue = Future.value();

  Future<T> _resetStorage<T>(Future<T> Function() action) {
    final operation = _resetStorageQueue.then((_) => action());
    // Keep the raw operation in the queue even when its caller times out.
    // A subsequent reset=true must commit after an already-issued remove.
    _resetStorageQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<T> _bounded<T>(
    Future<T> operation,
    Duration budget,
    CrispChatFailure failure, {
    CrispChatFailure? timeoutFailure,
  }) async {
    try {
      return await operation.timeout(budget);
    } on TimeoutException {
      throw CrispChatException(timeoutFailure ?? failure);
    } on CrispChatException {
      rethrow;
    } catch (_) {
      throw CrispChatException(failure);
    }
  }

  void _checkGeneration(int generation) {
    if (generation != _generation) {
      throw const CrispChatException(CrispChatFailure.cancelled);
    }
  }

  void _checkWindow(_DesktopCrispWindow view, int generation) {
    _checkGeneration(generation);
    if (view.closed || view.closing || !identical(_active, view)) {
      throw const CrispChatException(CrispChatFailure.windowClosed);
    }
  }

  Future<CreateConfiguration> _configuration(String websiteId) async {
    String? profilePath;
    if (_isWindows) {
      // path_provider resolves the app's per-user LocalAppData directory.
      // Keep the persistent profile outside the installed executable directory.
      final root = await _cacheDirectory();
      if (!p.isAbsolute(root.path)) {
        throw const CrispChatException(CrispChatFailure.profileUnavailable);
      }
      final site = sha256.convert(utf8.encode(websiteId)).toString();
      final profile = Directory(p.join(root.path, 'crisp', 'webview2', site));
      await profile.create(recursive: true);
      final probe = File(p.join(profile.path, '.write-check'));
      await probe.writeAsBytes(const [0], flush: true);
      await probe.delete();
      profilePath = profile.path;
    }
    return CreateConfiguration(
      title: '在线客服',
      titleBar: const TitleBarOptions(
        showNavigation: false,
        showReload: false,
        showHost: false,
      ),
      windowWidth: 420,
      windowHeight: 720,
      windows: WindowsWebviewOptions(
        userDataFolder: profilePath ?? 'webview_window_WebView2',
      ),
    );
  }

  @override
  Stream<void> get sessionLoaded => const Stream.empty();

  @override
  Future<void> open(CrispConfig config) async {
    final generation = ++_generation;
    if (config.websiteID.trim().isEmpty) {
      throw const CrispChatException(CrispChatFailure.notConfigured);
    }
    final existing = _active;
    if (existing != null &&
        !existing.closing &&
        !existing.closed &&
        existing.websiteId == config.websiteID) {
      // A late create from a timed-out attempt may still need a close event.
      for (final view in _windows.toList()) {
        if (!identical(view, existing)) await _closeWindow(view);
        _checkWindow(existing, generation);
      }
      try {
        await _bounded(
          _focusWindow(existing.window.nativeWindowHandle),
          _ioTimeout,
          CrispChatFailure.startupFailed,
        );
        _checkWindow(existing, generation);
        if (!existing.sessionReady || existing.loadFailed) {
          existing.loadFailed = false;
          // Restart a page that exhausted the service's readiness budget. The
          // bootstrap marker is cleared first so reload cannot accept old HTML.
          await _bounded(
            existing.window.evaluateJavaScript(
              'window.__xbCrispBootstrap=false; "ok";',
            ),
            _ioTimeout,
            CrispChatFailure.startupFailed,
          );
          _checkWindow(existing, generation);
          await _bounded(
            existing.window.reload(),
            _ioTimeout,
            CrispChatFailure.startupFailed,
          );
          _checkWindow(existing, generation);
          await _waitForBootstrap(existing, generation);
        }
        return;
      } catch (_) {
        if (generation == _generation) await _retire(existing);
        rethrow;
      }
    }

    await _closeAll();
    _checkGeneration(generation);
    await _bounded(
      _resetStorageQueue,
      _ioTimeout,
      CrispChatFailure.resetFailed,
    );
    _checkGeneration(generation);
    final available = await _bounded(
      Future.sync(_available),
      _ioTimeout,
      CrispChatFailure.startupFailed,
      timeoutFailure: CrispChatFailure.startupTimeout,
    );
    _checkGeneration(generation);
    if (!available) {
      throw CrispChatException(
        _isWindows
            ? CrispChatFailure.webView2Unavailable
            : CrispChatFailure.webViewUnavailable,
      );
    }
    final configuration = await _bounded(
      _configuration(config.websiteID),
      _ioTimeout,
      CrispChatFailure.profileUnavailable,
    );
    _checkGeneration(generation);
    final prefs = await _bounded(
      _preferences(),
      _ioTimeout,
      CrispChatFailure.resetFailed,
    );
    _checkGeneration(generation);
    final resetKey = 'xb_crisp_desktop_reset_${config.websiteID}';
    final pendingReset = prefs.getBool(resetKey) ?? false;
    final creatingDirectory = Directory.systemTemp.createTemp('xfl_crisp_');
    Directory directory;
    try {
      directory = await _bounded(
        creatingDirectory,
        _ioTimeout,
        CrispChatFailure.startupFailed,
      );
    } catch (_) {
      // A late temporary-directory result is local to this attempt.
      unawaited(
        creatingDirectory.then(_deleteDirectory, onError: (Object _) {}),
      );
      rethrow;
    }
    var ownsDirectory = true;
    _DesktopCrispWindow? view;
    try {
      _checkGeneration(generation);
      final file = File(p.join(directory.path, 'index.html'));
      await _bounded(
        file.writeAsString(
          desktopCrispHtml(
            config.websiteID,
            config.sessionSegment,
            pendingReset,
          ),
        ),
        _ioTimeout,
        CrispChatFailure.startupFailed,
      );
      _checkGeneration(generation);
      // Once create starts, only a confirmed native close may delete its HTML.
      final creatingWindow = Future.sync(() => _create(configuration));
      ownsDirectory = false;
      Webview window;
      try {
        window = await _bounded(
          creatingWindow,
          _startupTimeout,
          CrispChatFailure.startupFailed,
          timeoutFailure: CrispChatFailure.startupTimeout,
        );
      } catch (error) {
        unawaited(
          creatingWindow.then(
            (lateWindow) => _retire(
              _track(
                lateWindow,
                directory,
                config.websiteID,
                pendingReset ? resetKey : null,
              ),
            ),
            onError: (Object _) => _deleteDirectory(directory),
          ),
        );
        rethrow;
      }
      view = _track(
        window,
        directory,
        config.websiteID,
        pendingReset ? resetKey : null,
      );
      _checkGeneration(generation);
      _active = view;
      final ownedView = view;
      final page = file.uri;
      await _bounded(
        window.setOnUrlRequestCallback((url) {
          if (ownedView.closed ||
              ownedView.closing ||
              !identical(_active, ownedView)) {
            return false;
          }
          final action = crispNavigation(url, page);
          if (action == CrispNavigation.external) {
            // Windows asks synchronously: never call a native channel inside the
            // navigation decision. Dispatch only after it has returned.
            unawaited(
              Future<void>(() async {
                if (ownedView.closed ||
                    ownedView.closing ||
                    !identical(_active, ownedView) ||
                    ownedView.openingExternal) {
                  return;
                }
                ownedView.openingExternal = true;
                try {
                  final opened = await _openExternal(
                    Uri.parse(url),
                  ).timeout(_ioTimeout);
                  if (!opened) await _showExternalFailure(ownedView);
                } catch (_) {
                  await _showExternalFailure(ownedView);
                } finally {
                  ownedView.openingExternal = false;
                }
              }),
            );
          }
          return action == CrispNavigation.internal;
        }),
        _ioTimeout,
        CrispChatFailure.startupFailed,
      );
      _checkGeneration(generation);
      await _bounded(
        window.launch(page.toString()),
        _startupTimeout,
        CrispChatFailure.startupFailed,
        timeoutFailure: CrispChatFailure.startupTimeout,
      );
      await _waitForBootstrap(view, generation);
    } on CrispChatException {
      if (view != null) await _retire(view);
      rethrow;
    } catch (_) {
      if (view != null) await _retire(view);
      throw const CrispChatException(CrispChatFailure.startupFailed);
    } finally {
      if (ownsDirectory) await _deleteDirectory(directory);
    }
  }

  Future<void> _waitForBootstrap(
    _DesktopCrispWindow view,
    int generation,
  ) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < _startupTimeout) {
      _checkWindow(view, generation);
      if (view.loadFailed) {
        throw const CrispChatException(CrispChatFailure.startupFailed);
      }
      final remaining = _startupTimeout - elapsed.elapsed;
      final budget = remaining < _ioTimeout ? remaining : _ioTimeout;
      final result = await _bounded(
        view.window.evaluateJavaScript(
          r'(function(){return window.__xbCrispBootstrap ? "loaded" : "";})();',
        ),
        budget,
        CrispChatFailure.startupFailed,
        timeoutFailure: CrispChatFailure.startupTimeout,
      );
      _checkWindow(view, generation);
      if (_desktopString(result) == 'loaded') return;
      final pause = _startupTimeout - elapsed.elapsed;
      if (pause > Duration.zero) {
        await Future<void>.delayed(
          pause < _bootstrapPollInterval ? pause : _bootstrapPollInterval,
        );
      }
    }
    throw const CrispChatException(CrispChatFailure.startupTimeout);
  }

  @override
  Future<String?> sessionId() async {
    final view = _active;
    if (view == null || view.closing || view.closed) {
      throw const CrispChatException(CrispChatFailure.windowClosed);
    }
    if (view.loadFailed) {
      throw const CrispChatException(CrispChatFailure.sessionNotReady);
    }
    final generation = _generation;
    final value = _desktopString(
      await _bounded(
        view.window.evaluateJavaScript(
          r'(function(){if(window.__xbCrispLoadFailed)return "__xb_load_failed__";return window.__xbCrispReady ? String(window.__xbCrispSession || "") : "";})();',
        ),
        _ioTimeout,
        CrispChatFailure.sessionNotReady,
      ),
    );
    _checkWindow(view, generation);
    if (value == '__xb_load_failed__') {
      view.sessionReady = false;
      throw const CrispChatException(CrispChatFailure.sessionNotReady);
    }
    if (value == null || value.isEmpty || value == 'null') {
      view.sessionReady = false;
      return null;
    }
    final key = view.pendingResetKey;
    if (key != null) {
      final removed = await _bounded(
        _resetStorage(() async {
          _checkWindow(view, generation);
          final prefs = await _preferences();
          _checkWindow(view, generation);
          final removed = await prefs.remove(key);
          _checkWindow(view, generation);
          return removed;
        }),
        _ioTimeout,
        CrispChatFailure.resetFailed,
      );
      _checkWindow(view, generation);
      if (!removed) {
        throw const CrispChatException(CrispChatFailure.resetFailed);
      }
      view.pendingResetKey = null;
    }
    view.sessionReady = true;
    return value;
  }

  /// A failed child window must not cover the main window's recovery dialog.
  /// Keep the profile/reset marker and the existing close-confirmation barrier.
  Future<void> dismissFailedOpen() async {
    final view = _active;
    if (view != null) await _retire(view);
  }

  /// Reveal only after this account's context has been written successfully.
  Future<void> reveal() async {
    final view = _active;
    if (view == null || view.closed || view.closing) {
      throw const CrispChatException(CrispChatFailure.windowClosed);
    }
    final generation = _generation;
    try {
      final result = await _bounded(
        view.window.evaluateJavaScript(
          r'(function(){document.getElementById("status").textContent="";$crisp.push(["do","chat:show"]);$crisp.push(["do","chat:open"]);return "ok";})();',
        ),
        _ioTimeout,
        CrispChatFailure.sessionDataFailed,
      );
      _checkWindow(view, generation);
      if (result != 'ok') {
        throw const CrispChatException(CrispChatFailure.sessionDataFailed);
      }
    } catch (_) {
      if (generation == _generation) await _retire(view);
      rethrow;
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    final view = _active;
    if (view == null || view.closing || view.closed) {
      throw const CrispChatException(CrispChatFailure.windowClosed);
    }
    final generation = _generation;
    final command =
        '\$crisp.push(["set","session:data",[[[${jsonEncode(key)},${jsonEncode(value)}]]]]);';
    final identity = key == 'Email'
        ? '\$crisp.push(["set","user:email",[${jsonEncode(value)}]]);'
              '\$crisp.push(["set","user:nickname",[${jsonEncode(value.split('@').first)}]]);'
        : '';
    try {
      final result = await _bounded(
        view.window.evaluateJavaScript(
          '(function(){try{$command$identity return "ok";}catch(e){return "failed";}})();',
        ),
        _ioTimeout,
        CrispChatFailure.sessionDataFailed,
      );
      _checkWindow(view, generation);
      if (_desktopString(result) != 'ok') {
        throw const CrispChatException(CrispChatFailure.sessionDataFailed);
      }
    } catch (_) {
      // A pending native JS task stays bound to the old view. Do not reuse that
      // view for another identity after its acknowledgement times out.
      await _retire(view);
      rethrow;
    }
  }

  @override
  Future<void> reset(String websiteId) async {
    final generation = ++_generation;
    // Invalidate access before awaiting storage, and preserve the reset intent
    // across restart even if native close is never confirmed.
    for (final view in _windows) {
      view.closing = true;
    }
    _active = null;
    CrispChatException? failure;
    try {
      if (websiteId.isNotEmpty) {
        final saved = await _bounded(
          _resetStorage(() async {
            final prefs = await _preferences();
            // This conservative true write must survive cancellation. It owns
            // the captured website and cannot revive any account identity.
            return prefs.setBool('xb_crisp_desktop_reset_$websiteId', true);
          }),
          _ioTimeout,
          CrispChatFailure.resetFailed,
        );
        if (!saved) {
          throw const CrispChatException(CrispChatFailure.resetFailed);
        }
      }
      _checkGeneration(generation);
    } on CrispChatException catch (error) {
      failure = error;
    }
    try {
      await _closeAll();
    } on CrispChatException catch (error) {
      failure ??= error;
    }
    if (failure != null) throw failure;
    _checkGeneration(generation);
  }

  _DesktopCrispWindow _track(
    Webview window,
    Directory directory,
    String websiteId,
    String? pendingResetKey,
  ) {
    final view = _DesktopCrispWindow(
      window,
      directory,
      websiteId,
      pendingResetKey,
    );
    _windows.add(view);
    view.loadErrors = window.onLoadError.listen(
      (_) {
        if (!view.closed && !view.closing) {
          view.loadFailed = true;
          view.sessionReady = false;
        }
      },
      onError: (Object _) {
        view.loadFailed = true;
      },
    );
    view.nativeClose = window.onClose.then((_) {
      view.closed = true;
      unawaited(view.loadErrors?.cancel());
      if (identical(_active, view)) _active = null;
      _windows.remove(view);
      view.cleanup = _deleteDirectory(directory);
    });
    // Preserve rejection for close callers without creating an unhandled error.
    unawaited(view.nativeClose.then<void>((_) {}, onError: (Object _) {}));
    return view;
  }

  Future<void> _closeAll() async {
    CrispChatException? failure;
    for (final view in _windows.toList()) {
      try {
        await _closeWindow(view);
      } on CrispChatException catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  Future<void> _closeWindow(_DesktopCrispWindow view) async {
    view.closing = true;
    if (identical(_active, view)) _active = null;
    try {
      if (!view.closed) {
        await _bounded(
          view.window.close(),
          _closeTimeout,
          CrispChatFailure.closeFailed,
        );
      }
      await _bounded(
        view.nativeClose,
        _closeTimeout,
        CrispChatFailure.closeFailed,
      );
      await view.cleanup;
    } on CrispChatException {
      rethrow;
    } catch (_) {
      throw const CrispChatException(CrispChatFailure.closeFailed);
    }
  }

  Future<void> _retire(_DesktopCrispWindow view) async {
    try {
      await _closeWindow(view);
    } on CrispChatException {
      // It stays in _windows until a close event; the next open/reset retries.
    }
  }

  Future<void> _showExternalFailure(_DesktopCrispWindow view) async {
    if (view.closed || view.closing || !identical(_active, view)) return;
    try {
      await view.window
          .evaluateJavaScript('window.alert("无法打开外部链接，请复制链接后在浏览器打开。");')
          .timeout(_ioTimeout);
    } catch (_) {
      /* A closed window cannot show feedback. */
    }
  }

  Future<void> _deleteDirectory(Directory directory) async {
    try {
      await directory.delete(recursive: true).timeout(_ioTimeout);
    } catch (_) {
      // Temporary HTML has no account values; failed cleanup is best effort.
    }
  }
}

class _DesktopCrispWindow {
  _DesktopCrispWindow(
    this.window,
    this.directory,
    this.websiteId,
    this.pendingResetKey,
  );

  final Webview window;
  final Directory directory;
  final String websiteId;
  String? pendingResetKey;
  late final Future<void> nativeClose;
  Future<void>? cleanup;
  // Owned by _track; cancelled when the native onClose event completes.
  // ignore: cancel_subscriptions
  StreamSubscription<WebviewLoadError>? loadErrors;
  bool loadFailed = false;
  bool openingExternal = false;
  bool closed = false;
  bool closing = false;
  bool sessionReady = false;
}

/// No account data is placed in the temporary HTML. Escape script delimiters even
/// though website ID and segment normally contain only simple configuration text.
String desktopCrispHtml(String websiteId, String? segment, bool reset) {
  String js(String value) => jsonEncode(value).replaceAll('<', r'\u003c');
  return '''<!doctype html><html><head><meta charset="utf-8">
<title>在线客服</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{height:100%;margin:0}body{font:14px system-ui;color:#555}#status{padding:24px}</style></head>
<body><p id="status">正在加载客服，请稍候…</p><script>
window.CRISP_RUNTIME_CONFIG={lock_maximized:true,lock_full_view:true};
window.\$crisp=[];window.CRISP_WEBSITE_ID=${js(websiteId)};
window.__xbCrispReady=false;window.__xbCrispLoadFailed=false;
var resetPending=${reset ? 'true' : 'false'};
\$crisp.push(["do","chat:hide"]);
\$crisp.push(["on","session:loaded",function(id){
  if(resetPending){resetPending=false;\$crisp.push(["do","session:reset"]);return;}
  window.__xbCrispSession=id;window.__xbCrispReady=true;
  document.getElementById("status").textContent="正在同步客服资料…";
  ${segment == null ? '' : '\$crisp.push(["set","session:segments",[[${js(segment)}]]]);'}
}]);
setTimeout(function(){if(!window.__xbCrispReady){document.getElementById("status").textContent="客服加载较慢，请检查网络，关闭窗口后重试。";}},15000);
window.__xbCrispBootstrap=true;
</script><script src="https://client.crisp.chat/l.js" async
onerror="window.__xbCrispLoadFailed=true;document.getElementById('status').textContent='客服加载失败，请检查网络后重试。';"></script></body></html>''';
}

/// 0.4.0 decodes the native result once on every desktop platform.
String? _desktopString(Object? value) => value is String ? value : null;
