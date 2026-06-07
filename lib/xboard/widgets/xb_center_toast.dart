/// 形态 A 居中浮层提示（连接拦截用，spec `xboard-form-a-ui-revamp` 原型 `.toast`）。
///
/// **为什么不用 SnackBar**：SnackBar 只能贴底，原型要求「屏幕中央浮现、约 3 秒淡出」。
/// 用 [OverlayEntry] 自绘——居中(垂直略偏上，避开底栏视觉重心)，淡入淡出，到时自动移除。
///
/// 用法：`XbCenterToast.show(context, '当前无可用线路…', icon: Icons.warning_rounded)`。
/// 同一时刻只保留一个（再次调用先移除上一个），避免叠层。
library;

import 'package:flutter/material.dart';

import 'xb_theme.dart';

/// 居中浮层提示（琥珀 warn 风格，与原型黄框一致）。
class XbCenterToast {
  XbCenterToast._();

  static OverlayEntry? _current;

  /// 弹出居中浮层。[duration] 停留时长（默认 3 秒），到时淡出移除。
  static void show(
    BuildContext context,
    String message, {
    IconData icon = Icons.info_outline_rounded,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // 先移除上一个，避免叠层。
    _current?.remove();
    _current = null;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ToastWidget(
        message: message,
        icon: icon,
        duration: duration,
        onDismissed: () {
          if (_current == entry) _current = null;
          entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }
}

class _ToastWidget extends StatefulWidget {
  const _ToastWidget({
    required this.message,
    required this.icon,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final IconData icon;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _c.forward(); // 淡入。
    // 停留后淡出 → 移除。
    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _c.reverse();
      widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    const warn = XbTokens.warn;
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
                scale: Tween<double>(begin: 0.96, end: 1).animate(
                  CurvedAnimation(parent: _c, curve: Curves.easeOut),
                ),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 36),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                        warn.withValues(alpha: 0.13), t.card),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: warn.withValues(alpha: 0.34)),
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
                      Icon(widget.icon, size: 22, color: warn),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.55,
                            color: Color(0xFF8A6321),
                          ),
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
    );
  }
}
