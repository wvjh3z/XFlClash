import 'dart:async';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_tutorial.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:mocktail/mocktail.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

class _KnowledgeList extends Mock implements sdk.KnowledgeListApi {}

const _items = [
  sdk.KnowledgeItem(
    id: 21,
    category: '官方客户端',
    title: '原文教程标题',
    updatedAt: 1792022400,
  ),
];

void _expectCancelled(XbResult<List<XbTutorial>> result) {
  expect(result, isA<XbFailure<List<XbTutorial>>>());
  expect(
    result.errorOrNull,
    isA<XbNetwork>().having(
      (error) => error.kind,
      'kind',
      sdk.NetworkErrorKind.cancelled,
    ),
  );
}

void main() {
  late FakeXBoardSDK instance;
  late _KnowledgeList knowledgeList;

  setUp(() {
    instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    knowledgeList = _KnowledgeList();
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
  });

  test('initially inactive directory scope sends no SDK request', () async {
    var failoverCalls = 0;
    final service = XboardServiceImpl(
      sdk: instance,
      apiFailover: () async => failoverCalls++,
    );
    expect(service, isA<XboardTutorialRequestControl>());

    _expectCancelled(
      await service.getTutorialsForRequest(isActive: () => false),
    );
    verifyNever(knowledgeList.getKnowledgeList);
    verifyNever(() => instance.knowledgeList);
    expect(failoverCalls, 0);
  });

  test(
    'late network failure from inactive scope starts no failover or retry',
    () async {
      final response = Completer<List<sdk.KnowledgeItem>>();
      final started = Completer<void>();
      var active = true;
      var failoverCalls = 0;
      when(knowledgeList.getKnowledgeList).thenAnswer((_) {
        started.complete();
        return response.future;
      });
      final service = XboardServiceImpl(
        sdk: instance,
        apiFailover: () async => failoverCalls++,
      );
      final pending = service.getTutorialsForRequest(isActive: () => active);
      await started.future;

      active = false;
      response.completeError(sdk.NetworkException('fixture network failure'));

      _expectCancelled(await pending);
      verify(knowledgeList.getKnowledgeList).called(1);
      expect(failoverCalls, 0);
    },
  );

  test(
    'late successful directory response from inactive scope is discarded',
    () async {
      final response = Completer<List<sdk.KnowledgeItem>>();
      final started = Completer<void>();
      var active = true;
      var failoverCalls = 0;
      when(knowledgeList.getKnowledgeList).thenAnswer((_) {
        started.complete();
        return response.future;
      });
      final service = XboardServiceImpl(
        sdk: instance,
        apiFailover: () async => failoverCalls++,
      );
      final pending = service.getTutorialsForRequest(isActive: () => active);
      await started.future;

      active = false;
      response.complete(_items);

      _expectCancelled(await pending);
      verify(knowledgeList.getKnowledgeList).called(1);
      expect(failoverCalls, 0);
    },
  );

  test(
    'started shared failover may finish but inactive directory is not retried',
    () async {
      final failoverStarted = Completer<void>();
      final finishFailover = Completer<void>();
      var active = true;
      var failoverCalls = 0;
      var failoverCompleted = false;
      when(
        knowledgeList.getKnowledgeList,
      ).thenThrow(sdk.NetworkException('fixture network failure'));
      final service = XboardServiceImpl(
        sdk: instance,
        apiFailover: () async {
          failoverCalls++;
          failoverStarted.complete();
          await finishFailover.future;
          failoverCompleted = true;
        },
      );
      final pending = service.getTutorialsForRequest(isActive: () => active);
      await failoverStarted.future;

      active = false;
      finishFailover.complete();

      _expectCancelled(await pending);
      expect(failoverCompleted, isTrue);
      expect(failoverCalls, 1);
      verify(knowledgeList.getKnowledgeList).called(1);
    },
  );

  test(
    'active directory retains one failover and a successful retry',
    () async {
      var calls = 0;
      var failoverCalls = 0;
      when(knowledgeList.getKnowledgeList).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw sdk.NetworkException('fixture network failure');
        return _items;
      });
      final service = XboardServiceImpl(
        sdk: instance,
        apiFailover: () async => failoverCalls++,
      );

      final result = await service.getTutorialsForRequest(isActive: () => true);

      expect(result, isA<XbSuccess<List<XbTutorial>>>());
      expect(result.dataOrNull!.single.id, 21);
      expect(result.dataOrNull!.single.title, '原文教程标题');
      expect(failoverCalls, 1);
      verify(knowledgeList.getKnowledgeList).called(2);
    },
  );

  test(
    'retry response is discarded if directory becomes inactive in flight',
    () async {
      final retryStarted = Completer<void>();
      final retryResponse = Completer<List<sdk.KnowledgeItem>>();
      var active = true;
      var calls = 0;
      var failoverCalls = 0;
      when(knowledgeList.getKnowledgeList).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw sdk.NetworkException('fixture network failure');
        retryStarted.complete();
        return retryResponse.future;
      });
      final service = XboardServiceImpl(
        sdk: instance,
        apiFailover: () async => failoverCalls++,
      );
      final pending = service.getTutorialsForRequest(isActive: () => active);
      await retryStarted.future;

      active = false;
      retryResponse.complete(_items);

      _expectCancelled(await pending);
      expect(failoverCalls, 1);
      verify(knowledgeList.getKnowledgeList).called(2);
    },
  );
}
