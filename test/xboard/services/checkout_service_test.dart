import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/services/checkout_service.dart';

void main() {
  late CheckoutService sut;
  setUp(() => sut = CheckoutService());

  group('订单状态机（§ I）', () {
    test('shouldPoll：仅 pending/processing', () {
      expect(sut.shouldPoll(XbOrderStatus.pending), isTrue);
      expect(sut.shouldPoll(XbOrderStatus.processing), isTrue);
      expect(sut.shouldPoll(XbOrderStatus.completed), isFalse);
      expect(sut.shouldPoll(XbOrderStatus.cancelled), isFalse);
      expect(sut.shouldPoll(XbOrderStatus.discounted), isFalse);
    });

    test('isTerminal：cancelled/completed/discounted', () {
      expect(sut.isTerminal(XbOrderStatus.cancelled), isTrue);
      expect(sut.isTerminal(XbOrderStatus.completed), isTrue);
      expect(sut.isTerminal(XbOrderStatus.discounted), isTrue);
      expect(sut.isTerminal(XbOrderStatus.pending), isFalse);
    });

    test('shouldTriggerSync：completed/discounted → T3', () {
      expect(sut.shouldTriggerSync(XbOrderStatus.completed), isTrue);
      expect(sut.shouldTriggerSync(XbOrderStatus.discounted), isTrue);
      expect(sut.shouldTriggerSync(XbOrderStatus.cancelled), isFalse);
    });
  });

  group('processing 5min 超时（θ-7 单调时钟）', () {
    test('未记录 → 不超时', () {
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });

    test('刚进入 processing → 不超时', () {
      sut.markProcessing('T');
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });

    test('markProcessing 幂等（重复调用不重置计时）', () {
      sut.markProcessing('T');
      sut.markProcessing('T'); // 不重置
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });

    test('clearProcessing → 计时清除', () {
      sut.markProcessing('T');
      sut.clearProcessing('T');
      expect(sut.isProcessingTimedOut('T'), isFalse);
    });
  });
}
