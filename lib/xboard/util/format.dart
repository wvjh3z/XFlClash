/// 形态 A 通用格式化助手（金额 / 日期 / 流量 / 百分比）。
///
/// **设计意图**：金额 `¥x.toStringAsFixed(2)`、日期 `YYYY-MM-DD`、流量 GB、百分比等
/// 格式化散落在 9+ 处页面，各写一份易飘（精度/分隔/语义不一致）。集中到此，改一处全改。
/// 纯函数，无 UI / provider 依赖，可单测。
library;

/// 人民币金额（元）：`¥40.00`（始终两位小数）。
String xbYuan(double yuan) => '¥${yuan.toStringAsFixed(2)}';

/// 带符号人民币（用于优惠/抵扣行）：负数前缀 `-`，如 `-¥5.00`。
/// [yuan] 传正数表示「减免金额」，输出带负号；传负数原样反映。
String xbYuanMinus(double yuan) => '-¥${yuan.abs().toStringAsFixed(2)}';

/// 字节 → GB（保留 1 位小数，不带单位）：`245.7`。
String xbGb(int bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

/// 日期 `YYYY-MM-DD`。
String xbDate(DateTime d) =>
    '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';

/// 日期时间 `YYYY-MM-DD HH:mm:ss`。
String xbDateTime(DateTime d) =>
    '${xbDate(d)} ${_pad2(d.hour)}:${_pad2(d.minute)}:${_pad2(d.second)}';

/// 日期时间到分钟 `YYYY-MM-DD HH:mm`（到期 / 流量重置等展示用，秒无意义）。
String xbDateMinute(DateTime d) =>
    '${xbDate(d)} ${_pad2(d.hour)}:${_pad2(d.minute)}';

/// 百分比整数（四舍五入）：`62`（不带 % 号，调用方自行拼）。
int xbPercentInt(double ratio0to1) => (ratio0to1 * 100).round();

/// 剩余时间统一文案（到期 / 流量重置共用，框架化单一真源）：
/// - 剩余 >1 天 → `剩余N天`（向下取整）；
/// - 不足 1 天 → `剩余N小时`（向上取整，最少 1 小时）；
/// - 已过（diff<=0）→ 返回 [expiredText]（到期传「已过期」语义由调用方拼；流量重置每月循环、
///   target 恒在未来不会触发，默认 `剩余0小时` 仅兜底）。
String xbRemainLabel(DateTime target, {DateTime? now, String? expiredText}) {
  final base = now ?? DateTime.now();
  final ms = target.difference(base).inMilliseconds;
  if (ms <= 0) return expiredText ?? '剩余0小时';
  const dayMs = 86400000;
  if (ms >= dayMs) return '剩余${ms ~/ dayMs}天';
  final hours = (ms + 3600000 - 1) ~/ 3600000; // 向上取整
  return '剩余${hours < 1 ? 1 : hours}小时';
}

/// 流量重置行文案：`流量重置 每月N号HH:mm分（剩余N天/N小时）`。
///
/// [nextResetAt] = 后端 next_reset_at（下次重置时刻）。N号/时分取自它本身。剩余时间统一走
/// [xbRemainLabel]（与到期同口径，按真实时间差，不再「向上取整最少1天」）。每月循环故恒在未来。
String xbResetText(DateTime nextResetAt, {DateTime? now}) {
  final hm = '${_pad2(nextResetAt.hour)}:${_pad2(nextResetAt.minute)}';
  final remain = xbRemainLabel(nextResetAt, now: now);
  return '流量重置 每月${nextResetAt.day}号$hm分（$remain）';
}

/// 两位补零。
String _pad2(int n) => n.toString().padLeft(2, '0');
