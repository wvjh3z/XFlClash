/// 形态 A 居中浮层提示（连接拦截用，spec `xboard-form-a-ui-revamp` 原型 `.toast`）。
///
/// **为什么不用 SnackBar**：SnackBar 只能贴底，原型要求「屏幕中央浮现、约 3 秒淡出」。
/// 用 [OverlayEntry] 自绘——居中(垂直略偏上，避开底栏视觉重心)，淡入淡出，到时自动移除。
///
/// 用法：`XbCenterToast.show(context, '当前无可用线路…', icon: Icons.warning_rounded)`。
/// 同一时刻只保留一个（再次调用先移除上一个），避免叠层。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'xb_theme.dart';

enum XbToastTone { warning, info, success, error, neutral }

/// 居中浮层提示；默认保留原有琥珀色外观，可按业务结果指定标题和语义色。
class XbCenterToast {
  XbCenterToast._();

  static VoidCallback? _dismissCurrent;

  /// 弹出居中浮层。[duration] 停留时长（默认 3 秒），到时淡出移除。
  static VoidCallback? show(
    BuildContext context,
    String message, {
    IconData icon = Icons.info_outline_rounded,
    Duration duration = const Duration(seconds: 3),
    String? title,
    XbToastTone tone = XbToastTone.warning,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return null;

    // 先移除上一个，避免叠层。
    _dismissCurrent?.call();

    late final OverlayEntry entry;
    late final VoidCallback dismiss;
    var dismissed = false;
    dismiss = () {
      if (dismissed) return;
      dismissed = true;
      if (identical(_dismissCurrent, dismiss)) _dismissCurrent = null;
      entry.remove();
      entry.dispose();
    };
    entry = OverlayEntry(
      builder: (ctx) => _ToastWidget(
        message: message,
        icon: icon,
        duration: duration,
        title: title,
        tone: tone,
        onDismissed: dismiss,
      ),
    );
    _dismissCurrent = dismiss;
    overlay.insert(entry);
    return dismiss;
  }
}

class _ToastWidget extends StatefulWidget {
  const _ToastWidget({
    required this.message,
    required this.icon,
    required this.duration,
    required this.onDismissed,
    required this.title,
    required this.tone,
  });

  final String message;
  final IconData icon;
  final Duration duration;
  final VoidCallback onDismissed;
  final String? title;
  final XbToastTone tone;

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _c.forward(); // 淡入。
    // 停留后淡出 → 移除。
    _dismissTimer = Timer(widget.duration, () async {
      if (!mounted) return;
      try {
        await _c.reverse().orCancel;
        if (mounted) widget.onDismissed();
      } on TickerCanceled {
        // 提示被替换或所属页面已关闭。
      }
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final accent = switch (widget.tone) {
      XbToastTone.warning => XbTokens.warn,
      XbToastTone.info => XbTokens.info,
      XbToastTone.success => XbTokens.ok,
      XbToastTone.error => XbTokens.bad,
      XbToastTone.neutral => t.onv,
    };
    final foreground = switch (widget.tone) {
      XbToastTone.warning => t.onWarn,
      XbToastTone.success => t.onOk,
      XbToastTone.neutral => t.onv,
      _ =>
        Theme.of(context).brightness == Brightness.dark
            ? Color.lerp(accent, t.on, .35)!
            : accent,
    };
    return Positioned.fill(
      child: IgnorePointer(
        // 浮层不拦截点击（用户可继续操作下层）。
        child: SafeArea(
          child: Align(
            // 略偏上居中（屏幕中上部，避开底栏视觉重心）。
            alignment: const Alignment(0, -0.15),
            child: FadeTransition(
              opacity: _c,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.82, end: 1).animate(
                  CurvedAnimation(
                    parent: _c,
                    // 入场用回弹曲线（带过冲）更俏皮；退场线性淡出即可。
                    curve: Curves.easeOutBack,
                    reverseCurve: Curves.easeOut,
                  ),
                ),
                // Material 包裹：Overlay 直挂根、无 Material 祖先 → 裸 Text 会渲染黄黑下划线
                // （Flutter「missing Material」提示）。透明 Material 提供文本渲染祖先，消下划线。
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    // 桌面宽窗口下限制最大宽度，避免横向拉得过宽（移动端窄屏不受影响）。
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 36),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 15,
                      ),
                      decoration: BoxDecoration(
                        color: Color.alphaBlend(
                          accent.withValues(alpha: 0.13),
                          t.card,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.34),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 30,
                            spreadRadius: -8,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.icon,
                            size: 22,
                            color: widget.tone == XbToastTone.warning
                                ? accent
                                : foreground,
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: widget.title == null
                                ? Text(
                                    widget.message,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.55,
                                      color: foreground,
                                    ),
                                  )
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.title!,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          height: 1.5,
                                          color: foreground,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        widget.message,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.7,
                                          color: foreground,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
