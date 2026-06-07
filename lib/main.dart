import 'dart:async';
import 'dart:io';

import 'package:fl_clash/pages/error.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
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
    // config: dart-define 编译期值（W8.5，prepare_flavor 生成 flavor_defines.json 注入；
    // 无注入则用占位默认）。
    try {
      // 先显式 bind flavor 配置（含 XB_FORM_A），保证即便 bootstrap 同步阶段抛异常被吞，
      // `XboardConfig.current.formA` 在首帧渲染时也已正确。
      XboardConfig.bind(XboardConfig.fromEnvironment());
      await XboardModule.bootstrap(
        container,
        config: XboardConfig.fromEnvironment(),
      );
    } catch (_) {
      // swallow（W8.3 SentryBootstrap 完成后尽力上报）
    }

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const Application(),
      ),
    );

    // === Xboard 接缝点 #1.bis（W5 异步阶段，runApp 后 fire-and-forget，DD-17 render-first）===
    // 远端 Bootstrap 拉取 + endpoint 竞速 + baseUrl 热替换；绝不 await（不阻塞首屏）+ 永不抛（DD-2）。
    unawaited(XboardModule.bootstrapAsync(container));
  } catch (e, s) {
    return runApp(
      MaterialApp(
        home: InitErrorScreen(error: e, stack: s),
      ),
    );
  }
}
