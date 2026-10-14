/// Compatibility for the pinned Windows WebView environment lifecycle.
library;

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart'
    show InternalChannelController;
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

/// Windows 0.6.0 creates the native environment under [environment.id], but
/// binds its Dart channel to the factory instance's ID. Repair that binding so
/// the public dispose API releases this environment, including late creations.
/// Remove after a dependency upgrade fixes the upstream binding.
void repairTutorialWebViewEnvironment(WebViewEnvironment environment) {
  final platform = environment.platform;
  if (platform is! WindowsWebViewEnvironment || platform.disposed) return;
  final name =
      'com.pichillilorenzo/flutter_webview_environment_${environment.id}';
  if (platform.channel?.name == name) return;

  final handler = platform.handler;
  platform.disposeChannel();
  platform.channel = MethodChannel(name);
  platform.handler = handler;
  platform.initMethodCallHandler();
}
