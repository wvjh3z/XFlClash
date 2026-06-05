/// 形态 A 连接球（spec `xboard-form-a-ui-revamp` / W3.1 / R2.1·R2.3·R2.4·R2.5·R8.5）。
///
/// **现代扁平风**（非拟物玻璃球，R8.5）：细轨道环 + 留白核心 + 主题色进度环 + 图标/文字表达状态。
/// 已连接用**主题色**（`colorScheme.primary`，非绿色语义色，R2.3）。
///
/// **四态**（读 `XbConnectAdapter.connState`，design 风险②叠加 coreStatus）：
/// - booting：启动中，操作禁用（R2.5），转圈
/// - disconnected：核心留白 + 中性色图标/「未连接」
/// - connecting：主题色进度弧转动（R2.4），操作进行中
/// - connected：主题色完整环 + 主题色图标/「已连接」（R2.3）
///
/// **适配层铁律**：本文件在 `lib/xboard/shell/tabs/`，**禁止**直接 import lib/views/**；
/// 一切内核交互经 `XbConnectAdapter`（W2.1）。点击 → `adapter.toggle`。
///
/// **文案约束（R2.5）**：不出现「节点 / 优选 / 线路 / 竞速」等技术词。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adapters/xb_connect_adapter.dart';

/// 连接球四态外形。
class XbConnectOrb extends ConsumerWidget {
  const XbConnectOrb({super.key, this.size = 208});

  /// 连接球直径。
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(xbConnectAdapterProvider);
    final state = adapter.connState(ref);
    final scheme = Theme.of(context).colorScheme;

    final enabled = state != XbConnState.booting;
    return Semantics(
      button: true,
      enabled: enabled,
      label: _semanticLabel(state),
      child: GestureDetector(
        onTap: enabled ? () => adapter.toggle(ref) : null,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 轨道环（静态细环，留白底）。
              _TrackRing(size: size, color: scheme.surfaceContainerHighest),
              // 进度环（连接态主题色满环 / 连接中主题色弧转动）。
              _ProgressRing(size: size, state: state, color: scheme.primary),
              // 核心（留白 + 图标 + 状态文字）。
              _OrbCore(size: size * 0.79, state: state, scheme: scheme),
            ],
          ),
        ),
      ),
    );
  }

  String _semanticLabel(XbConnState state) => switch (state) {
        XbConnState.booting => '准备中',
        XbConnState.disconnected => '未连接，点击连接',
        XbConnState.connecting => '连接中',
        XbConnState.connected => '已连接，点击断开',
      };
}

class _TrackRing extends StatelessWidget {
  const _TrackRing({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 3),
      ),
    );
  }
}

class _ProgressRing extends StatefulWidget {
  const _ProgressRing({
    required this.size,
    required this.state,
    required this.color,
  });

  final double size;
  final XbConnState state;
  final Color color;

  @override
  State<_ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<_ProgressRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  bool get _isSpinning =>
      widget.state == XbConnState.connecting ||
      widget.state == XbConnState.booting;

  @override
  void initState() {
    super.initState();
    if (_isSpinning) _spin.repeat();
  }

  @override
  void didUpdateWidget(_ProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isSpinning && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!_isSpinning && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spin,
      builder: (context, _) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _ProgressPainter(
            state: widget.state,
            color: widget.color,
            rotation: _spin.value,
          ),
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.state,
    required this.color,
    required this.rotation,
  });

  final XbConnState state;
  final Color color;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.5;
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.width - stroke) / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    switch (state) {
      case XbConnState.connected:
        // 主题色完整环。
        canvas.drawCircle(center, radius, paint);
      case XbConnState.connecting:
      case XbConnState.booting:
        // 主题色弧（约 120°）随 rotation 旋转。
        final start = rotation * 2 * 3.1415926535;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start,
          2.094, // ~120°
          false,
          paint..color = color.withValues(
            alpha: state == XbConnState.booting ? 0.5 : 1.0,
          ),
        );
      case XbConnState.disconnected:
        // 无进度环（仅轨道环可见）。
        break;
    }
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.state != state || old.rotation != rotation || old.color != color;
}

class _OrbCore extends StatelessWidget {
  const _OrbCore({required this.size, required this.state, required this.scheme});

  final double size;
  final XbConnState state;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final connected = state == XbConnState.connected;
    final active = connected || state == XbConnState.connecting;
    final iconColor = active ? scheme.primary : scheme.onSurfaceVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface,
        border: Border.all(
          color: active
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_icon(state), size: 52, color: iconColor),
          const SizedBox(height: 10),
          Text(
            _statusText(state),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
              color: active ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _subText(state),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  IconData _icon(XbConnState state) => switch (state) {
        XbConnState.connected => Icons.shield,
        XbConnState.connecting => Icons.shield_outlined,
        XbConnState.booting => Icons.hourglass_empty,
        XbConnState.disconnected => Icons.power_settings_new,
      };

  String _statusText(XbConnState state) => switch (state) {
        XbConnState.connected => '已连接',
        XbConnState.connecting => '连接中',
        XbConnState.booting => '准备中',
        XbConnState.disconnected => '未连接',
      };

  String _subText(XbConnState state) => switch (state) {
        XbConnState.connected => '点击断开',
        XbConnState.connecting => '正在建立连接',
        XbConnState.booting => '正在准备',
        XbConnState.disconnected => '点击连接',
      };
}
