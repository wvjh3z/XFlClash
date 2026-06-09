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

/// 流量重置行文案：`每月N号HH:mm分（剩余N天）`。
///
/// [nextResetAt] = 后端 next_reset_at（下次重置时刻）。N号/时分取自它本身（不用后端 reset_day，
/// 那个口径与实际下次重置日对不上、会误导）。剩余天数 = `ceil((nextResetAt - now)/天)` **向上取整**，
/// 最少 1 天（剩 1 小时也显示「剩余1天」，绝不显示「剩余0天」）。已过期 → `剩余0天`（兜底，正常不出现）。
String xbResetText(DateTime nextResetAt, {DateTime? now}) {
  final base = now ?? DateTime.now();
  final hm = '${_pad2(nextResetAt.hour)}:${_pad2(nextResetAt.minute)}';
  final ms = nextResetAt.difference(base).inMilliseconds;
  // 向上取整：未过期(ms>0)时 ceil 必 ≥1，故「剩 1 小时」也得「剩余1天」；已过期 → 0。
  final left = ms <= 0 ? 0 : ((ms + 86400000 - 1) ~/ 86400000);
  return '流量重置 每月${nextResetAt.day}号$hm分（剩余$left天）';
}

/// 两位补零。
String _pad2(int n) => n.toString().padLeft(2, '0');
