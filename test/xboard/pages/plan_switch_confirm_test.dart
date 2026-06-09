/// 更换套餐确认触发契约（原型 16b）：shouldConfirmPlanSwitch 纯函数。
///
/// 仅当「当前有仍生效（未到期）套餐 + 所选 ≠ 当前 + 非续费」时才弹确认；
/// 旧套餐已到期 / 无生效套餐 / 续费 / 选的就是当前套餐 → 视为正常下单，不提示。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';

XbDomainSubscription _sub({
  int? planId = 1,
  int totalBytes = 250,
  DateTime? expiredAt,
}) =>
    XbDomainSubscription(
      email: 'u@example.com',
      uuid: 'uuid',
      planName: '标准套餐',
      totalBytes: totalBytes,
      usedBytes: 0,
      expiredAt: expiredAt,
      planId: planId,
    );

void main() {
  final now = DateTime(2026, 6, 10, 12);
  final future = DateTime(2026, 7, 1); // 未到期
  final past = DateTime(2026, 5, 1); // 已到期

  group('shouldConfirmPlanSwitch', () {
    test('当前生效套餐 + 换不同套餐 → 提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: 1, expiredAt: future),
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isTrue,
      );
    });

    test('长期有效（expiredAt=null）+ 换不同套餐 → 提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: 1, expiredAt: null),
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isTrue,
      );
    });

    test('旧套餐已到期 → 视为全新选购，不提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: 1, expiredAt: past),
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isFalse,
      );
    });

    test('选的就是当前套餐（续费同套餐）→ 不提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: 2, expiredAt: future),
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isFalse,
      );
    });

    test('续费模式 → 永不提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: 1, expiredAt: future),
          newPlanId: 2,
          isRenew: true,
          now: now,
        ),
        isFalse,
      );
    });

    test('无当前套餐（null）→ 不提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: null,
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isFalse,
      );
    });

    test('无套餐（hasNoPlan：planId=null 或 totalBytes=0）→ 不提示', () {
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: null, expiredAt: future),
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldConfirmPlanSwitch(
          current: _sub(planId: 1, totalBytes: 0, expiredAt: future),
          newPlanId: 2,
          isRenew: false,
          now: now,
        ),
        isFalse,
      );
    });
  });
}
