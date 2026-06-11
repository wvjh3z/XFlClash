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

import '../../../widgets/xb_motion.dart';
import '../../adapters/xb_connect_adapter.dart';
import '../../adapters/xb_nodes_adapter.dart';
import '../../adapters/xb_network_adapter.dart';

/// 连接拦截原因（首页连接球点击 gate）：未登录 / 无可用线路 / 线路准备中。
enum XbConnectBlock {
  /// 未登录 → 提示先登录。
  notLoggedIn,

  /// 已登录但无可用线路（profile 无 proxy-group，套餐到期/未生效）→ 提示刷新/购买。
  noNodes,

  /// 已登录、线路正在准备（订阅 sync in-flight，profile 还没生成）→ 提示稍候。
  preparing,
}

/// 连接球四态外形。
class XbConnectOrb extends ConsumerStatefulWidget {
  const XbConnectOrb({
    super.key,
    this.size = 177,
    this.showLock = false,
    this.guest = false,
    this.onBlocked,
  });

  /// 连接球直径。
  final double size;

  /// 游客态：核心右下角显示锁徽章（原型 guest orb）。
  final bool showLock;

  /// 游客态：未连接时文案显示「未登录 / 点击登录」（原型 guest orb）。
  final bool guest;

  /// 连接拦截回调（HomeTab 注入）：返回拦截原因则**不连接**、走该回调（弹居中提示）；
  /// 返回 null 表示放行 → 正常 toggle。仅在「未连接 → 发起连接」方向拦截（断开不拦）。
  final XbConnectBlock? Function()? onBlocked;

  @override
  ConsumerState<XbConnectOrb> createState() => _XbConnectOrbState();
}

class _XbConnectOrbState extends ConsumerState<XbConnectOrb>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  /// 用户是否主动发起了连接（点击连接球/线路卡连接）。
  ///
  /// **为何需要**：FlClash 的 `coreStatus==connecting` 在**冷启动预热 clash 核心**时也会出现
  /// （`connectCore()`，与用户连 VPN 无关）。若直接映射成「连接中」，冷启动没开 VPN 也会闪一下
  /// 「正在建立加密隧道」。故仅在用户主动连接时才认作「连接中」，否则核心预热 → 显示「准备中」。
  bool _connectIntent = false;

  /// 连上瞬间的回弹 pop（一次性）：scale 0.9 → 1.08 → 1.0。
  /// 静止值 = 1.0（controller 初始 value=1.0 → TweenSequence 末态 1.0），
  /// 未触发时核心保持原尺寸；forward(from:0) 才播放回弹。
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
    value: 1.0,
  );
  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.08), weight: 45),
    TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0), weight: 55),
  ]).animate(CurvedAnimation(parent: _pop, curve: Curves.easeOut));

  XbConnState? _prevState;

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(xbConnectAdapterProvider);
    final raw = adapter.connState(ref);
    // 冷启动核心预热（connecting，但既非用户发起、VPN 也未开启）→ 当作「准备中」，
    // 不显示「连接中/建立加密隧道」。用户发起连接(_connectIntent) 或 VPN 已开(startIntended) 才认作连接中。
    final state = (raw == XbConnState.connecting &&
            !_connectIntent &&
            !adapter.startIntended(ref))
        ? XbConnState.booting
        : raw;
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    final reduced = XbMotion.reduced(context);

    // 状态跃迁 → 连上瞬间触发 pop（reduce-motion 跳过）。
    if (_prevState != null &&
        _prevState != XbConnState.connected &&
        state == XbConnState.connected &&
        !reduced) {
      _pop.forward(from: 0);
    }
    _prevState = state;

    final enabled = state != XbConnState.booting;
    final connecting = state == XbConnState.connecting;
    final pressScale = (_pressed && !reduced) ? 0.96 : 1.0;

    return Semantics(
      button: true,
      enabled: enabled,
      label: _semanticLabel(state),
      child: GestureDetector(
        onTap: enabled ? () => _handleTap(ref, state) : null,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: () => _set(false),
        child: AnimatedScale(
          scale: pressScale,
          duration: XbMotion.fast,
          curve: XbMotion.standard,
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 连接中：向外扩散的声呐脉冲（比单纯转圈更"正在建立连接"）。
                if (connecting && !reduced)
                  _SonarLayer(size: size, color: scheme.primary),
                // 轨道环（静态细环，留白底）。
                _TrackRing(size: size, color: scheme.surfaceContainerHighest),
                // 进度环（连接态主题色满环 / 连接中主题色弧转动）。
                _ProgressRing(size: size, state: state, color: scheme.primary),
                // 核心（留白 + 图标 + 状态文字）；连上回弹 pop。
                ScaleTransition(
                  scale: _popScale,
                  child: _OrbCore(
                    size: size * 0.79,
                    state: state,
                    scheme: scheme,
                    guest: widget.guest,
                  ),
                ),
                // 游客锁徽章（右下角，原型 guest orb）。
                if (widget.showLock)
                  Positioned(
                    right: size * 0.08,
                    bottom: size * 0.04,
                    child: Container(
                      width: size * 0.18,
                      height: size * 0.18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.surfaceContainerLow,
                        border: Border.all(color: scheme.outlineVariant),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Icon(Icons.lock,
                          size: size * 0.085, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 点击处理：仅在「未连接 → 连接」方向先过拦截 gate；已连接（断开）/ 连接中直接放行。
  void _handleTap(WidgetRef ref, XbConnState state) {
    final adapter = ref.read(xbConnectAdapterProvider);
    final initiatingConnect = state == XbConnState.disconnected;
    if (initiatingConnect && widget.onBlocked != null) {
      final block = widget.onBlocked!();
      if (block != null) return; // 被拦截（回调内已弹提示），不连接。
    }
    // 记录连接意图：发起连接 → true（让 connecting 态认作真实连接中）；断开 → false。
    _connectIntent = initiatingConnect;
    adapter.toggle(ref);
    // 发起连接时测一次当前生效节点延迟（3 次取最低，刷到首页速度卡）。fire-and-forget。
    if (initiatingConnect) {
      // ignore: discarded_futures
      ref.read(xbNodesAdapterProvider).measureCurrentNodeBest(ref);
    }
    // 连接/断开后重新检测出口 IP（VPN 出口会变；延后让连接态切换后再测）。
    ref.read(xbNetworkAdapterProvider).startCheck(ref);
  }

  String _semanticLabel(XbConnState state) => switch (state) {
        XbConnState.booting => '准备中',
        XbConnState.disconnected => '未连接，点击连接',
        XbConnState.connecting => '连接中',
        XbConnState.connected => '已连接，点击断开',
      };
}

/// 连接中声呐脉冲层：两层向外扩散的环（错相），表达「正在建立连接」。
/// 仅 connecting 时挂载 → 仅此时循环（与进度环 spinner 同款 golden 安全性）。
class _SonarLayer extends StatefulWidget {
  const _SonarLayer({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  State<_SonarLayer> createState() => _SonarLayerState();
}

class _SonarLayerState extends State<_SonarLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _SonarPainter(progress: _c.value, color: widget.color),
        );
      },
    );
  }
}

class _SonarPainter extends CustomPainter {
  _SonarPainter({required this.progress, required this.color});

  /// 0→1 循环进度。
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseR = size.width / 2;
    // 两层错相（相差半个周期）。
    for (final phase in [0.0, 0.5]) {
      final t = (progress + phase) % 1.0;
      final r = baseR * (0.72 + 0.62 * t); // 0.72→1.34 扩散
      final opacity = (0.5 * (1 - t)).clamp(0.0, 0.5);
      if (opacity <= 0.01) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: opacity);
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(_SonarPainter old) =>
      old.progress != progress || old.color != color;
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
  const _OrbCore({
    required this.size,
    required this.state,
    required this.scheme,
    this.guest = false,
  });

  final double size;
  final XbConnState state;
  final ColorScheme scheme;
  final bool guest;

  @override
  Widget build(BuildContext context) {
    final connected = state == XbConnState.connected;
    final active = connected || state == XbConnState.connecting;
    final iconColor = active ? scheme.primary : scheme.onSurfaceVariant;
    // 游客 + 未连接：文案「未登录 / 点击登录」（原型 guest orb）。
    final guestIdle = guest && state == XbConnState.disconnected;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerLowest,
        border: Border.all(
          color: active
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.outlineVariant,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: active
                ? scheme.primary.withValues(alpha: 0.22)
                : Colors.black.withValues(alpha: 0.12),
            blurRadius: 30,
            spreadRadius: -8,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_icon(state), size: size * 0.316, color: iconColor),
          const SizedBox(height: 10),
          Text(
            guestIdle ? '未登录' : _statusText(state),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
              color: active ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            guestIdle ? '点击登录' : _subText(state),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  IconData _icon(XbConnState state) => switch (state) {
        XbConnState.connected => Icons.verified_user,
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
        XbConnState.connected => '数据已加密保护',
        XbConnState.connecting => '正在建立加密隧道…',
        XbConnState.booting => '正在准备服务',
        XbConnState.disconnected => '点击连接',
      };
}
