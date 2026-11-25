import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import '../../_fixtures/fake_xboard_sdk.dart';
import 'order_http_fixture.dart';

void main() {
  const path = '/api/v1/user/invite/details?current=1&page_size=10';
  List<Map<String, int>> rows(int n) => List.generate(n, (i) => {'id': i+1, 'get_amount': 100});
  for (final (name, payload, expected) in <(String, Map<String,dynamic>, int?)>[
    ('empty', {'data': [], 'total': 0}, 0),
    ('nine', {'data': rows(9), 'total': 9}, 9),
    ('ten', {'data': rows(10), 'total': 10}, 10),
    ('more pages', {'data': rows(10), 'total': 27}, 10),
    ('nested', {'data': {'data': rows(9), 'total': 9}}, 9),
    ('missing', {'total': 0}, null),
    ('inconsistent', {'data': [], 'total': 10}, null),
    ('error', {'success':false, 'data': []}, null),
    ('duplicate', {'data': [...rows(9), ...rows(1)]}, null),
  ]) {
    test('withdrawal count: $name', () async {
      final sdk = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
      final http = OrderFixtureHttp();
      when(() => sdk.httpService).thenReturn(http);
      when(() => http.getRequest(path)).thenAnswer((_) async => payload);
      final result = await XboardServiceImpl(sdk:sdk).getWithdrawalRecordCount();
      expect(result.isSuccess, expected != null);
      expect(result.dataOrNull,expected);
      verify(() => http.getRequest(path)).called(1);
    });
  }
}
