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

/// 两位补零。
String _pad2(int n) => n.toString().padLeft(2, '0');
