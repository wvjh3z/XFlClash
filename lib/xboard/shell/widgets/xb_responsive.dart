/// 形态 A 桌面响应式布局**单一真源**（spec `xboard-form-a-ui-revamp` / C-分支）。
///
/// **框架思维**：把「窄/宽断点」「内容限宽随窗口分级增长」的策略集中在这一处，
/// 各 Tab / 弹窗都从这里派生，不再各自散落 `maxWidth: 1000` 魔法数字。
/// 改一处全改；新增屏幕自动遵循同一策略；回归由 `desktop_scaling_test` 守护。
///
/// **4K / 大屏优化**：内容限宽不再恒为 1000，而是按可用宽度**分级放大**——
/// 大窗口（2K/4K@100%）内容更宽、用满空间，而非永远 1000px 孤零居中。
/// （4K 常规用法是系统缩放 150%/200%，逻辑尺寸≈1080P，此时走基准档，行为同 1080P。）
library;

/// 桌面响应式断点（逻辑像素，按「内容区可用宽度」判定，非全局窗口宽）。
abstract final class XbBreakpoints {
  /// 桌面双栏 / master-detail 的最小可用宽度；窄于此回退移动端单列。
  static const double desktop = 840;

  /// 弹窗改居中模态对话框的最小窗口宽度；窄于此用底部 sheet。
  static const double dialog = 600;

  // —— 内容限宽分级阈值 ——
  static const double _wide = 1680; // 2K 级：内容放宽
  static const double _ultra = 2400; // 4K@100% 级：内容进一步放宽
}

/// 内容区限宽策略（单一真源）：随「可用宽度」分级增长，避免大屏上内容过窄孤立。
///
/// - 基准档（≤1680，含 1080P / 4K@200%）：1000（与原型 `.dwrap` 一致）
/// - 宽档（1680–2400，2K@100% 等）：1240
/// - 超宽档（≥2400，4K@100%）：1480
///
/// [extra]：master-detail 等需在基准上额外加宽的场景（如节点页含 200 分组栏 + 20 间隔）。
double xbContentMaxWidth(double availableWidth, {double extra = 0}) {
  final double base;
  if (availableWidth >= XbBreakpoints._ultra) {
    base = 1480;
  } else if (availableWidth >= XbBreakpoints._wide) {
    base = 1240;
  } else {
    base = 1000;
  }
  return base + extra;
}

/// 可用宽度是否达到桌面双栏阈值。
bool xbIsDesktopWidth(double availableWidth) =>
    availableWidth >= XbBreakpoints.desktop;
