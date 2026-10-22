import 'dart:async';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/xboard_module.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'application.dart';
import 'bootstrap.dart';
import 'common/app_data.dart';
import 'common/common.dart';
import 'common/preferences_store.dart';
import 'common/window.dart';

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      try {
        // Crisp's title-bar child must not claim the main process data lock.
        if (system.isDesktop && runWebViewTitleBarWidget(args)) return;
        if (system.isDesktop && !await singleInstanceLock.acquire()) exit(0);
        if (Platform.isWindows || Platform.isLinux) {
          SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
            appPath.sharedPreferencesPath,
          );
        }
        if (Platform.isLinux) {
          linkManager.seedInitialLink(args);
        }

        final xboardConfig = XboardConfig.fromEnvironment();
        await XboardModule.initializeMonitoringEarly(config: xboardConfig);
        await RustLib.init();
        final version = await system.init();
        final container = await bootstrap.init(version);
        await FlClashHttpOverrides.trustCoreRoots();
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        try {
          await XboardModule.bootstrap(container, config: xboardConfig);
        } catch (error, stackTrace) {
          XboardModule.captureStartupFailure('main Xboard bootstrap', error, stackTrace);
        }
        runApp(
          UncontrolledProviderScope(
            container: container,
            child: const Application(),
          ),
        );
        unawaited(XboardModule.bootstrapAsync(container));
      } catch (e, s) {
        XboardModule.captureStartupFailure('main initialization', e, s);
        runApp(
          InitErrorApp(
            error: e,
            stack: s,
            onClearData: clearAppData,
            onExit: _exitAfterInitFailure,
          ),
        );
        unawaited(window?.showInitFailure(onExit: _exitAfterInitFailure));
      }
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

Future<void> _exitAfterInitFailure() async {
  await system.exit();
  window?.forceExit();
}
