import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/config.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class Window {
  static Window? _instance;

  Window._internal();

  factory Window() {
    _instance ??= Window._internal();
    return _instance!;
  }

  Future<void> init(int version, WindowProps props) async {
    final acquire = await singleInstanceLock.acquire();
    if (!acquire) {
      exit(0);
    }
    if (system.isWindows) {
      protocol.register('clash');
      protocol.register('clashmeta');
      protocol.register('flclash');
    }
    await windowManager.ensureInitialized();
    // === Xboard 接缝点 #17（form-a 桌面默认窗口尺寸）===
    // formA 桌面：未保存过尺寸时用更大的默认窗口（1280×800 / 最小 1000×680），已保存尺寸
    // （用户拖拽过）则尊重用户。非 formA 保持上游 680×580 / 380×400 不变。居中由
    // _windowPosition 在 left/top 未设时处理。
    // ⚠️ 直接读 dart-define（非 XboardConfig.current）：window.init 在 globalState.init 阶段执行，
    // 早于 main.dart 的 XboardConfig.bind()，此刻 XboardConfig.current 还是 formA=false 的占位默认。
    const bool isFormA = bool.fromEnvironment('XB_FORM_A', defaultValue: false);
    final bool noSavedSize = props.width <= 0 || props.height <= 0;
    final WindowOptions windowOptions = WindowOptions(
      size: (isFormA && noSavedSize) ? const Size(1280, 800) : props.size,
      minimumSize: isFormA ? const Size(1000, 680) : const Size(380, 400),
    );
    if (!system.isMacOS || version > 10) {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
    await windowManager.setMaximizable(true);
    await _windowPosition(props);
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
    });
  }

  Future<void> _windowPosition(WindowProps props) async {
    if (!system.isMacOS) {
      final left = props.left ?? 0;
      final top = props.top ?? 0;
      final right = left + props.width;
      final bottom = top + props.height;
      if (left == 0 && top == 0) {
        await windowManager.setAlignment(Alignment.center);
      } else {
        final displays = await screenRetriever.getAllDisplays();
        final isPositionValid = displays.any((display) {
          final displayBounds = Rect.fromLTWH(
            display.visiblePosition!.dx,
            display.visiblePosition!.dy,
            display.size.width,
            display.size.height,
          );
          return displayBounds.contains(Offset(left, top)) ||
              displayBounds.contains(Offset(right, bottom));
        });
        if (isPositionValid) {
          await windowManager.setPosition(Offset(left, top));
        }
      }
    }
  }

  Future<void> show() async {
    render?.resume();
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setSkipTaskbar(false);
  }

  Future<bool> get isVisible async {
    final value = await windowManager.isVisible();
    commonPrint.log('window visible check: $value');
    return value;
  }

  Future<void> close() async {
    await windowManager.close();
  }

  void forceExit() {
    exit(0);
  }

  Future<void> hide() async {
    render?.pause();
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }
}

final window = system.isDesktop ? Window() : null;
