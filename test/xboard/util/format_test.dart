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

  test('xbDateMinute YYYY-MM-DD HH:mm（到分钟，补零）', () {
    expect(xbDateMinute(DateTime(2026, 7, 1, 8, 30)), '2026-07-01 08:30');
    expect(xbDateMinute(DateTime(2026, 6, 12, 0, 0)), '2026-06-12 00:00');
  });

  test('xbPercentInt 四舍五入', () {
    expect(xbPercentInt(0.625), 63);
    expect(xbPercentInt(0.9), 90);
    expect(xbPercentInt(0), 0);
  });

  group('xbResetText 流量重置文案（>1天→剩余N天 / 不足1天→剩余N小时，与到期同口径）', () {
    test('整 5 天 → 剩余5天，取 nextResetAt 的日/时分', () {
      final now = DateTime(2026, 6, 4, 11, 17);
      final reset = DateTime(2026, 6, 9, 11, 17);
      expect(xbResetText(reset, now: now), '流量重置 每月9号11:17分（剩余5天）');
    });

    test('剩 1 小时（不足 1 天）→ 剩余1小时（不再夸大成 1 天）', () {
      final now = DateTime(2026, 6, 9, 10, 17);
      final reset = DateTime(2026, 6, 9, 11, 17);
      expect(xbResetText(reset, now: now), '流量重置 每月9号11:17分（剩余1小时）');
    });

    test('剩 1 天又 8 小时 → 剩余1天（>1天向下取整）', () {
      final now = DateTime(2026, 6, 8, 3, 0);
      final reset = DateTime(2026, 6, 9, 11, 17);
      expect(xbResetText(reset, now: now), '流量重置 每月9号11:17分（剩余1天）');
    });

    test('正好整 1 天 → 剩余1天', () {
      final now = DateTime(2026, 6, 8, 11, 17);
      final reset = DateTime(2026, 6, 9, 11, 17);
      expect(xbResetText(reset, now: now), '流量重置 每月9号11:17分（剩余1天）');
    });

    test('剩 5 小时半 → 向上取整 剩余6小时', () {
      final now = DateTime(2026, 6, 9, 5, 47);
      final reset = DateTime(2026, 6, 9, 11, 17);
      expect(xbResetText(reset, now: now), '流量重置 每月9号11:17分（剩余6小时）');
    });

    test('时分补零 + 2天9小时 → 剩余2天', () {
      final now = DateTime(2026, 6, 1, 0, 0);
      final reset = DateTime(2026, 6, 3, 9, 5);
      expect(xbResetText(reset, now: now), '流量重置 每月3号09:05分（剩余2天）');
    });

    test('已过期（now 晚于重置）→ 剩余0小时（兜底，每月循环正常不出现）', () {
      final now = DateTime(2026, 6, 10, 0, 0);
      final reset = DateTime(2026, 6, 9, 11, 17);
      expect(xbResetText(reset, now: now), '流量重置 每月9号11:17分（剩余0小时）');
    });
  });

  group('xbRemainLabel 剩余时间统一文案', () {
    test('>1天 向下取整', () {
      expect(
          xbRemainLabel(DateTime(2026, 6, 9, 11),
              now: DateTime(2026, 6, 4, 3)),
          '剩余5天');
    });
    test('不足1天 → 小时，向上取整', () {
      expect(
          xbRemainLabel(DateTime(2026, 6, 9, 11),
              now: DateTime(2026, 6, 9, 5, 1)),
          '剩余6小时');
    });
    test('正好1天 → 剩余1天', () {
      expect(
          xbRemainLabel(DateTime(2026, 6, 9, 11),
              now: DateTime(2026, 6, 8, 11)),
          '剩余1天');
    });
    test('已过 + expiredText → 返回 expiredText', () {
      expect(
          xbRemainLabel(DateTime(2026, 6, 8),
              now: DateTime(2026, 6, 9), expiredText: '已过期'),
          '已过期');
    });
    test('已过无 expiredText → 兜底剩余0小时', () {
      expect(
          xbRemainLabel(DateTime(2026, 6, 8), now: DateTime(2026, 6, 9)),
          '剩余0小时');
    });
  });
}
