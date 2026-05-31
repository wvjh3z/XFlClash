import 'dart:async';
import 'dart:io';

import 'package:fl_clash/pages/error.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/xboard_module.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';

import 'application.dart';
import 'common/common.dart';

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    if (system.isDesktop) {
      await RustLib.init();
    }
    final version = await system.version;
    final container = await globalState.init(version);
    HttpOverrides.global = FlClashHttpOverrides();

    // === Xboard 接缝点 #1（决策 #16 / DD-2.bis 双层 try/catch 隔离）===
    // 内层 XboardModule.bootstrap 已全捕获（DD-2）；此处外层再兜底，
    // 绝不让 Xboard 故障把 FlClash + VPN 一起拖进 InitErrorScreen。
    try {
      await XboardModule.bootstrap(container);
    } catch (_) {
      // swallow（W8.3 SentryBootstrap 完成后尽力上报）
    }

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const Application(),
      ),
    );
  } catch (e, s) {
    return runApp(
      MaterialApp(
        home: InitErrorScreen(error: e, stack: s),
      ),
    );
  }
}
