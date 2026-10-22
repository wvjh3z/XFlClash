/// Native tutorial view; SDK authentication stays outside this component.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/html_link.dart';
import '../services/tutorial_webview_environment.dart';
import '../services/xboard_release_dio.dart';
import 'tutorial_html_fallback.dart';
import 'xb_components.dart';

class TutorialWebView extends StatefulWidget {
  const TutorialWebView({
    super.key,
    required this.html,
    required this.resourceBase,
    required this.onOpenTutorial,
    required this.articleUrl,
  });
  final String html;
  final Uri resourceBase;
  final Future<void> Function(int id) onOpenTutorial;
  final Uri articleUrl;

  @override
  State<TutorialWebView> createState() => _TutorialWebViewState();
}

class _TutorialWebViewState extends State<TutorialWebView> {
  WebViewEnvironment? _environment;
  Directory? _profile;
  bool _ready = false;
  bool _missingRuntime = false;
  String? _error;
  int _generation = 0;
  int _progress = 0;
  Key _nativeKey = UniqueKey();
  Timer? _loadDeadline;

  bool get _supported =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    // Debug events may contain article content, copy values or private links.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    PlatformWebViewEnvironment.debugLoggingSettings.enabled = false;
    if (_supported) unawaited(_initialize());
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _initialize() async {
    final generation = ++_generation;
    WebViewEnvironment? environment;
    Directory? profile;
    try {
      if (defaultTargetPlatform == TargetPlatform.windows &&
          utf8.encode(widget.html).length >= 2 * 1024 * 1024) {
        setState(() => _error = '教程正文较大，请在浏览器中查看。');
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final version = await WebViewEnvironment.getAvailableVersion().timeout(
          const Duration(seconds: 5),
        );
        if (!_current(generation)) return;
        if (version == null || version.isEmpty) {
          setState(() {
            _missingRuntime = true;
            _error = '需要安装 Microsoft Edge WebView2 才能查看教程。';
          });
          return;
        }
        final cache = await getApplicationCacheDirectory();
        final root = Directory(p.join(cache.path, 'tutorial', 'webview2'));
        await root.create(recursive: true);
        profile = await root.createTemp('reader-');
        final probe = File(p.join(profile.path, '.write-check'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        final creating =
            WebViewEnvironment.create(
              settings: WebViewEnvironmentSettings(
                userDataFolder: profile.path,
                // The pinned Windows plugin does not forward server trust
                // challenges; apply the shared policy to this reader process.
                additionalBrowserArguments:
                    XboardReleaseHttp.allowBadCertificate
                    ? '--ignore-certificate-errors'
                    : null,
              ),
            ).then((value) {
              repairTutorialWebViewEnvironment(value);
              return value;
            });
        // A timed-out native creation may still finish. Retire that late result.
        unawaited(
          creating
              .then((value) async {
                if (!_current(generation)) await _release(value, profile);
              })
              .catchError((Object _) {}),
        );
        environment = await creating.timeout(const Duration(seconds: 10));
      }
      if (!_current(generation)) {
        await _release(environment, profile);
        return;
      }
      setState(() {
        _environment = environment;
        _profile = profile;
        _ready = true;
      });
      _loadDeadline = Timer(const Duration(seconds: 20), () {
        if (_current(generation) && _progress < 100) {
          ++_generation;
          setState(() => _error = '教程阅读器加载超时，请重试。');
        }
      });
    } catch (_) {
      final current = _current(generation);
      if (current) ++_generation;
      await _release(environment, profile);
      if (mounted && current) {
        setState(() => _error = '无法打开教程阅读器，请重试。');
      }
    }
  }

  Future<void> _release(
    WebViewEnvironment? environment,
    Directory? profile,
  ) async {
    try {
      await environment?.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (profile != null) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          if (await profile.exists()) await profile.delete(recursive: true);
          return;
        } catch (_) {
          // Browser processes can hold files briefly after controller disposal.
          if (attempt < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
      }
      // Never reuse a private folder that is still held by native processes.
    }
  }

  void _retry() {
    _loadDeadline?.cancel();
    final environment = _environment;
    final profile = _profile;
    ++_generation;
    setState(() {
      _environment = null;
      _profile = null;
      _ready = false;
      _missingRuntime = false;
      _error = null;
      _progress = 0;
      _nativeKey = UniqueKey();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _release(environment, profile);
      if (mounted) unawaited(_initialize());
    });
  }

  Future<bool> _open(String raw, int generation) async {
    if (!_current(generation)) return false;
    final uri = resolveHtmlLink(raw, base: widget.resourceBase.toString());
    if (uri == null || uri.userInfo.isNotEmpty) return false;
    if (uri.host == widget.resourceBase.host &&
        uri.scheme == widget.resourceBase.scheme &&
        uri.port == widget.resourceBase.port) {
      final match = RegExp(r'^/docs/(\d+)$').firstMatch(uri.fragment);
      if (match != null) {
        final id = int.tryParse(match.group(1)!);
        if (id != null && id > 0) {
          await widget.onOpenTutorial(id);
          return _current(generation);
        }
      }
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _loadDeadline?.cancel();
    ++_generation;
    unawaited(_release(_environment, _profile));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return TutorialHtmlFallback(
        html: widget.html,
        resourceBase: widget.resourceBase,
      );
    }
    final error = _error;
    if (error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          XbErrorRetry(message: error, onRetry: _retry),
          if (_missingRuntime)
            TextButton(
              onPressed: () => _open(
                'https://developer.microsoft.com/microsoft-edge/webview2/',
                _generation,
              ),
              child: const Text('下载 WebView2'),
            ),
          TextButton(
            onPressed: () async {
              try {
                await launchUrl(
                  widget.articleUrl,
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {}
            },
            child: const Text('在浏览器中查看'),
          ),
        ],
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final generation = _generation;
    return Column(
      children: [
        if (_progress < 100)
          LinearProgressIndicator(
            value: _progress > 0 ? _progress / 100 : null,
          ),
        Expanded(
          child: InAppWebView(
            key: _nativeKey,
            webViewEnvironment: _environment,
            initialData: InAppWebViewInitialData(
              data: widget.html,
              baseUrl: WebUri('about:blank'),
              mimeType: 'text/html',
              encoding: 'utf-8',
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              // Android incognito clears cookies shared by other WebViews.
              incognito: defaultTargetPlatform != TargetPlatform.android,
              cacheEnabled: false,
              domStorageEnabled: false,
              useShouldOverrideUrlLoading: true,
              useOnDownloadStart: true,
              supportMultipleWindows: true,
              javaScriptCanOpenWindowsAutomatically: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              allowFileAccess: false,
              disableContextMenu: false,
            ),
            onReceivedServerTrustAuthRequest: (_, _) async =>
                ServerTrustAuthResponse(
                  action:
                      _current(generation) &&
                          XboardReleaseHttp.allowBadCertificate
                      ? ServerTrustAuthResponseAction.PROCEED
                      : ServerTrustAuthResponseAction.CANCEL,
                ),
            onWebViewCreated: (controller) {
              controller.addJavaScriptHandler(
                handlerName: 'tutorialCopy',
                callback: (arguments) async {
                  if (!_current(generation) ||
                      arguments.length != 1 ||
                      arguments.first is! String) {
                    return false;
                  }
                  try {
                    await Clipboard.setData(
                      ClipboardData(text: arguments.first as String),
                    );
                    return _current(generation);
                  } catch (_) {
                    return false;
                  }
                },
              );
              controller.addJavaScriptHandler(
                handlerName: 'tutorialLink',
                callback: (arguments) async =>
                    arguments.length == 1 && arguments.first is String
                    ? _open(arguments.first as String, generation)
                    : false,
              );
            },
            onProgressChanged: (_, progress) {
              if (_current(generation)) setState(() => _progress = progress);
            },
            onLoadStop: (_, _) {
              if (_current(generation)) {
                _loadDeadline?.cancel();
                setState(() => _progress = 100);
              }
            },
            onConsoleMessage: (_, message) {
              // This fixed marker confirms the prepared DOM/reader script,
              // without waiting for every image or logging page content.
              if (_current(generation) &&
                  message.message == '__xb_tutorial_ready__') {
                _loadDeadline?.cancel();
                setState(() => _progress = 100);
              }
            },
            onReceivedError: (_, request, _) {
              if (_current(generation) && request.isForMainFrame == true) {
                _loadDeadline?.cancel();
                setState(() => _error = '教程加载失败，请重试。');
              }
            },
            shouldOverrideUrlLoading: (_, action) async {
              final raw = action.request.url?.toString() ?? '';
              if (_current(generation) &&
                  ((raw.isEmpty && _progress == 0) ||
                      raw == 'about:blank' ||
                      raw.startsWith('about:blank#') ||
                      raw.startsWith('data:text/html'))) {
                return NavigationActionPolicy.ALLOW;
              }
              if (action.isForMainFrame) await _open(raw, generation);
              return NavigationActionPolicy.CANCEL;
            },
            onCreateWindow: (_, action) async {
              await _open(action.request.url?.toString() ?? '', generation);
              return false;
            },
            onDownloadStartRequest: (_, request) =>
                _open(request.url.toString(), generation),
            onPermissionRequest: (_, request) async => PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.DENY,
            ),
          ),
        ),
      ],
    );
  }
}
