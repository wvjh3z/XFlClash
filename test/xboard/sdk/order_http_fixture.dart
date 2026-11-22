import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:flutter_xboard_sdk/src/core/http/http_service.dart';
import 'package:mocktail/mocktail.dart';

class OrderFixtureHttp extends Mock implements HttpService {
  @override
  bool get endpointRecoveryEnabled => false;

  @override
  Future<T> withRequestValidity<T>(
    bool Function() current,
    Future<T> Function() body,
  ) => current()
      ? Future.sync(body)
      : Future.error(RequestNotDispatchedException('stale fixture request'));
}

String orderDetailPath(String tradeNo) =>
    '/api/v1/user/order/detail?trade_no=$tradeNo';

Map<String, dynamic> orderWireDetail({
  Object? tradeNo = 'T',
  Object? status = 0,
  Object? amount = 100,
  Object? planId = 1,
  Object? period = 'month_price',
}) => {
  'success': true,
  'data': {
    'trade_no': tradeNo,
    'status': status,
    'total_amount': amount,
    'period': period,
    'plan_id': planId,
  },
};
