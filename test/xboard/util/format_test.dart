/// format.dart 单测（金额 / 日期 / 流量 / 百分比格式化）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/util/format.dart';

void main() {
  test('xbYuan 两位小数 + ¥', () {
    expect(xbYuan(40), '¥40.00');
    expect(xbYuan(35.5), '¥35.50');
    expect(xbYuan(0), '¥0.00');
  });

  test('xbYuanMinus 带负号', () {
    expect(xbYuanMinus(5), '-¥5.00');
    expect(xbYuanMinus(5.5), '-¥5.50');
  });

  test('xbGb 字节→GB 1 位小数', () {
    expect(xbGb(250 * 1024 * 1024 * 1024), '250.0');
    expect(xbGb(0), '0.0');
  });

  test('xbDate YYYY-MM-DD 补零', () {
    expect(xbDate(DateTime(2026, 7, 1)), '2026-07-01');
    expect(xbDate(DateTime(2026, 12, 31)), '2026-12-31');
  });

  test('xbDateTime YYYY-MM-DD HH:mm:ss 补零', () {
    expect(xbDateTime(DateTime(2026, 6, 5, 9, 3, 7)), '2026-06-05 09:03:07');
  });

  test('xbPercentInt 四舍五入', () {
    expect(xbPercentInt(0.625), 63);
    expect(xbPercentInt(0.9), 90);
    expect(xbPercentInt(0), 0);
  });
}
