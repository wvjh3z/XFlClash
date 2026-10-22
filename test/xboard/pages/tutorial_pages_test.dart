/// 教程目录与页面状态回归；原生 WebView 的 DOM/排版需平台验收。
library;

import 'dart:async';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_tutorial.dart';
import 'package:fl_clash/xboard/pages/tutorial_detail_page.dart';
import 'package:fl_clash/xboard/pages/tutorial_list_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/tutorial_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:mocktail/mocktail.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

class _Knowledge extends Mock implements sdk.KnowledgeApi {}

class _KnowledgeList extends Mock implements sdk.KnowledgeListApi {}

class _Config extends Mock implements sdk.ConfigApi {}

class _Service extends Mock implements XboardService {}

class _Auth extends AuthStateNotifier {
  _Auth(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

const _listTitle = '  Windows — 默认安装说明  ';

XbTutorial _tutorial({int id = 21, String title = _listTitle}) =>
    XbTutorial(id: id, title: title, updatedAt: DateTime(2026, 10, 14));

Future<ProviderContainer> _pumpList(
  WidgetTester tester,
  XboardService service, {
  bool guest = false,
  List<TutorialReaderContent>? readerInputs,
  Duration? listTimeout,
  Brightness brightness = Brightness.light,
}) async {
  final container = ProviderContainer(
    // 目录 provider 自己关闭自动重试；保留真实容器默认策略验证错误立即可见。
    overrides: [
      xboardServiceProvider.overrideWithValue(service),
      if (listTimeout != null)
        tutorialListTimeoutProvider.overrideWithValue(listTimeout),
      authStateProvider.overrideWith(
        () =>
            _Auth(guest ? AuthState.unauthenticated : AuthState.authenticated),
      ),
      if (readerInputs != null)
        tutorialReaderBuilderProvider.overrideWithValue((context, content) {
          readerInputs.add(content);
          return _ReaderPlaceholder(onDispose: () {});
        }),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const TutorialListPage(),
      ),
    ),
  );
  await _finish(tester);
  return container;
}

Future<void> _finish(WidgetTester tester) async {
  // 加载骨架可能一直有动画，等待有限帧而非 pumpAndSettle。
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

Future<void> _pullList(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 420));
  await _finish(tester);
}

const _emptyDescription = '教程正在准备中，请稍后再来看看。';
const _failureTitle = '教程加载失败';
const _failureDescription = '暂时无法加载，请稍后重试。';
const _timeoutTitle = '加载超时';
const _timeoutDescription = '等待时间较长，请重试。';

void _expectListState(String title, String description, String action) {
  expect(find.text(title, findRichText: true), findsOneWidget);
  expect(find.text(description, findRichText: true), findsOneWidget);
  expect(find.text(action), findsOneWidget);
}

enum _ListState { empty, failure, timeout, normal }

XbResult<List<XbTutorial>> _listResponse(_ListState state) => switch (state) {
  _ListState.empty => const XbSuccess(<XbTutorial>[]),
  _ListState.failure => const XbFailure(
    XbNetwork(XbNetworkKind.connectionFailed, '受控网络错误详情'),
  ),
  _ListState.timeout => const XbFailure(
    XbNetwork(XbNetworkKind.timeout, '受控超时错误详情'),
  ),
  _ListState.normal => XbResult.success([_tutorial(title: '刷新前的目录')]),
};

void _expectInitialListState(_ListState state) {
  switch (state) {
    case _ListState.empty:
      _expectListState('暂无使用教程', _emptyDescription, '刷新');
    case _ListState.failure:
      _expectListState(_failureTitle, _failureDescription, '重试');
    case _ListState.timeout:
      _expectListState(_timeoutTitle, _timeoutDescription, '重试');
    case _ListState.normal:
      expect(find.text('刷新前的目录'), findsOneWidget);
  }
}

class _ReaderPlaceholder extends StatefulWidget {
  const _ReaderPlaceholder({required this.onDispose});
  final VoidCallback onDispose;

  @override
  State<_ReaderPlaceholder> createState() => _ReaderPlaceholderState();
}

class _ReaderPlaceholderState extends State<_ReaderPlaceholder> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: Key('native-reader-placeholder'));
}

class _DetailFixture {
  final service = _Service();
  final inputs = <TutorialReaderContent>[];
  late ProviderContainer container;
  int nativeDisposals = 0;

  Future<void> pump(WidgetTester tester, {bool guest = false}) async {
    container = ProviderContainer(
      retry: (retryCount, error) => null,
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        authStateProvider.overrideWith(
          () => _Auth(
            guest ? AuthState.unauthenticated : AuthState.authenticated,
          ),
        ),
        tutorialReaderBuilderProvider.overrideWithValue((context, content) {
          inputs.add(content);
          return _ReaderPlaceholder(onDispose: () => nativeDisposals++);
        }),
      ],
    );
    container
        .read(apiEndpointProvider.notifier)
        .set('https://tutorials.example.invalid');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TutorialDetailPage(id: 21)),
      ),
    );
    await _finish(tester);
  }
}

XbTutorialDetail _detail(String body, {int id = 21}) => XbTutorialDetail(
  id: id,
  title: '后台文章标题',
  body: body,
  updatedAt: DateTime(2026, 10, 14),
);

void main() {
  group('教程资源源站与正文请求', () {
    late FakeXBoardSDK instance;
    late _Knowledge knowledge;
    late _Config config;
    const article = sdk.KnowledgeArticle(
      id: 21,
      category: '官方客户端',
      title: '后台文章标题',
      body: '<h1>服务端原有标题</h1><img src="/images/step.png">',
      updatedAt: 1791936000,
    );

    void bind({String resourceBase = ''}) => XboardConfig.bind(
      XboardConfig(
        subscribeUserAgent: 'tutorial-test flclash',
        devApiEndpoint: 'https://api-mirror.example.invalid',
        devSubscriptionEndpoint: 'https://subscription.example.invalid',
        tutorialBaseUrl: resourceBase,
        debug: false,
        kIsTest: true,
      ),
    );

    setUp(() {
      bind();
      instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
      knowledge = _Knowledge();
      config = _Config();
      when(() => instance.knowledge).thenReturn(knowledge);
      when(() => instance.config).thenReturn(config);
      when(
        () => knowledge.getKnowledgeDetail(21),
      ).thenAnswer((_) async => article);
    });
    tearDown(XboardConfig.resetForTest);

    test('品牌资源源站独立于API镜像，配置后不额外请求guest配置', () async {
      bind(
        resourceBase:
            ' https://content.example.invalid/manual?locale=zh#/docs/21 ',
      );
      final service = XboardServiceImpl(sdk: instance);
      final result = await service.getTutorialDetail(21);
      expect(result, isA<XbSuccess<XbTutorialDetail>>());
      final detail = (result as XbSuccess<XbTutorialDetail>).data;

      expect(detail.resourceBase, 'https://content.example.invalid/manual/');
      expect(detail.body, article.body);
      expect(detail.title, article.title);
      verifyNever(config.getConfig);
      verify(() => knowledge.getKnowledgeDetail(21)).called(1);
    });

    test('未配置品牌源站时使用app_url，清除query/hash并缓存成功源站', () async {
      when(config.getConfig).thenAnswer(
        (_) async => const sdk.ConfigModel(
          appUrl: 'https://content.example.invalid/reader?ui=desktop#/docs/21',
        ),
      );
      final service = XboardServiceImpl(sdk: instance);

      for (var index = 0; index < 2; index++) {
        final result = await service.getTutorialDetail(21);
        expect(result, isA<XbSuccess<XbTutorialDetail>>());
        final detail = (result as XbSuccess<XbTutorialDetail>).data;
        expect(detail.resourceBase, 'https://content.example.invalid/reader/');
        final base = Uri.parse(detail.resourceBase!);
        expect(base.hasQuery, isFalse);
        expect(base.hasFragment, isFalse);
        expect(detail.body, article.body);
      }
      verify(config.getConfig).called(1);
      verify(() => knowledge.getKnowledgeDetail(21)).called(2);
    });

    test('辅助guest配置请求失败，不阻断已成功取得的知识库正文', () async {
      when(config.getConfig).thenThrow(StateError('controlled guest failure'));
      final result = await XboardServiceImpl(
        sdk: instance,
      ).getTutorialDetail(21);

      expect(result, isA<XbSuccess<XbTutorialDetail>>());
      final detail = (result as XbSuccess<XbTutorialDetail>).data;
      expect(detail.body, article.body);
      expect(detail.title, article.title);
      expect(detail.resourceBase, isNull);
      verify(config.getConfig).called(1);
      verify(() => knowledge.getKnowledgeDetail(21)).called(1);
    });
  });

  testWidgets('目录只展示官方客户端，标题原文和后端顺序均保留', (tester) async {
    final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    final knowledgeList = _KnowledgeList();
    final knowledge = _Knowledge();
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
    when(() => instance.knowledge).thenReturn(knowledge);
    when(knowledgeList.getKnowledgeList).thenAnswer(
      (_) async => const [
        sdk.KnowledgeItem(
          id: 19,
          category: 'Android教程',
          title: '其他分类的教程',
          updatedAt: 1791936000,
        ),
        sdk.KnowledgeItem(
          id: 30,
          category: '官方客户端',
          title: _listTitle,
          updatedAt: 1791936000,
        ),
        sdk.KnowledgeItem(
          id: 21,
          category: '官方客户端',
          title: 'Android 使用步骤',
          updatedAt: 1791849600,
        ),
        sdk.KnowledgeItem(
          id: 40,
          category: '官方客户端说明',
          title: '相似分类也不展示',
          updatedAt: 1791936000,
        ),
      ],
    );
    final service = XboardServiceImpl(sdk: instance);
    await _pumpList(tester, service);

    expect(find.text(_listTitle), findsOneWidget);
    expect(find.text('Android 使用步骤'), findsOneWidget);
    expect(find.text('其他分类的教程'), findsNothing);
    expect(find.text('相似分类也不展示'), findsNothing);
    expect(find.text('官方客户端 · 使用教程'), findsNothing);
    expect(
      tester.getTopLeft(find.text(_listTitle)).dy,
      lessThan(tester.getTopLeft(find.text('Android 使用步骤')).dy),
    );
    verify(knowledgeList.getKnowledgeList).called(1);
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(() => knowledge.getKnowledgeDetail(any()));
    expect(find.byType(TutorialDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有官方客户端文章时显示空态，不回退到其他分类', (tester) async {
    final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    final knowledgeList = _KnowledgeList();
    final knowledge = _Knowledge();
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
    when(() => instance.knowledge).thenReturn(knowledge);
    when(knowledgeList.getKnowledgeList).thenAnswer(
      (_) async => const [
        sdk.KnowledgeItem(
          id: 19,
          category: 'Android教程',
          title: '其他分类的教程',
          updatedAt: 1791936000,
        ),
      ],
    );
    await _pumpList(tester, XboardServiceImpl(sdk: instance));

    expect(find.text('暂无使用教程', findRichText: true), findsOneWidget);
    expect(find.text(_emptyDescription, findRichText: true), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('其他分类的教程'), findsNothing);
    verify(knowledgeList.getKnowledgeList).called(1);
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(() => knowledge.getKnowledgeDetail(any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('轻量目录为空时显示空态，不拉全文目录或正文', (tester) async {
    final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    final knowledgeList = _KnowledgeList();
    final knowledge = _Knowledge();
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
    when(() => instance.knowledge).thenReturn(knowledge);
    when(knowledgeList.getKnowledgeList).thenAnswer((_) async => const []);
    await _pumpList(tester, XboardServiceImpl(sdk: instance));

    expect(find.text('暂无使用教程', findRichText: true), findsOneWidget);
    verify(knowledgeList.getKnowledgeList).called(1);
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(() => knowledge.getKnowledgeDetail(any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录只取元数据；点击文章才取该篇正文并创建阅读器', (tester) async {
    XboardConfig.bind(
      const XboardConfig(
        subscribeUserAgent: 'tutorial-test flclash',
        devApiEndpoint: 'https://api.example.invalid',
        devSubscriptionEndpoint: 'https://subscription.example.invalid',
        tutorialBaseUrl: 'https://content.example.invalid/',
        debug: false,
        kIsTest: true,
      ),
    );
    addTearDown(XboardConfig.resetForTest);
    final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    final knowledgeList = _KnowledgeList();
    final knowledge = _Knowledge();
    final config = _Config();
    final inputs = <TutorialReaderContent>[];
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
    when(() => instance.knowledge).thenReturn(knowledge);
    when(() => instance.config).thenReturn(config);
    when(knowledgeList.getKnowledgeList).thenAnswer(
      (_) async => const [
        sdk.KnowledgeItem(
          id: 21,
          category: '官方客户端',
          title: _listTitle,
          updatedAt: 1791936000,
        ),
        sdk.KnowledgeItem(
          id: 22,
          category: '官方客户端',
          title: '尚未点开的文章',
          updatedAt: 1791936000,
        ),
      ],
    );
    when(() => knowledge.getKnowledgeDetail(21)).thenAnswer(
      (_) async => const sdk.KnowledgeArticle(
        id: 21,
        category: '官方客户端',
        title: _listTitle,
        body: '<h1>教程正文原有标题</h1><p>点选后才取得正文</p>',
        updatedAt: 1791936000,
      ),
    );
    await _pumpList(
      tester,
      XboardServiceImpl(sdk: instance),
      readerInputs: inputs,
    );

    expect(inputs, isEmpty);
    expect(find.byType(TutorialDetailPage), findsNothing);
    verify(knowledgeList.getKnowledgeList).called(1);
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(() => knowledge.getKnowledgeDetail(any()));
    verifyNever(config.getConfig);

    await tester.tap(find.text(_listTitle));
    await _finish(tester);
    expect(find.byType(TutorialDetailPage), findsOneWidget);
    expect(find.byKey(const Key('native-reader-placeholder')), findsOneWidget);
    expect(inputs, isNotEmpty);
    expect(inputs.last.html, contains('教程正文原有标题'));
    expect(inputs.last.html, contains('点选后才取得正文'));
    verify(() => knowledge.getKnowledgeDetail(21)).called(1);
    verifyNever(() => knowledge.getKnowledgeDetail(22));
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(config.getConfig);
    expect(tester.takeException(), isNull);
  });

  for (final status in [400, 404]) {
    testWidgets('目录插件返回$status时保留登录且不回退全文，点击重试仍走轻量接口', (tester) async {
      final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
      final knowledgeList = _KnowledgeList();
      final knowledge = _Knowledge();
      var calls = 0;
      var failoverCalls = 0;
      when(() => instance.knowledgeList).thenReturn(knowledgeList);
      when(() => instance.knowledge).thenReturn(knowledge);
      when(knowledgeList.getKnowledgeList).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw sdk.ApiException('测试目录插件不可用', status);
        return const [
          sdk.KnowledgeItem(
            id: 21,
            category: '官方客户端',
            title: _listTitle,
            updatedAt: 1791936000,
          ),
        ];
      });
      final container = await _pumpList(
        tester,
        XboardServiceImpl(
          sdk: instance,
          apiFailover: () async => failoverCalls++,
        ),
      );

      expect(find.text('重试'), findsOneWidget);
      _expectListState(_failureTitle, _failureDescription, '重试');
      expect(find.text('测试目录插件不可用', findRichText: true), findsNothing);
      expect(find.text('暂无使用教程', findRichText: true), findsNothing);
      expect(calls, 1);
      expect(failoverCalls, 0, reason: '插件不可用属于业务错误，无需切换网络地址');
      expect(container.read(authStateProvider), AuthState.authenticated);
      verifyNever(instance.clearToken);
      verifyNever(() => instance.clearTokenIfSession(any()));
      verifyNever(knowledge.getKnowledgeList);
      verifyNever(() => knowledge.getKnowledgeDetail(any()));

      await tester.tap(find.text('重试'));
      await _finish(tester);
      expect(calls, 2);
      expect(find.text(_listTitle), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(container.read(authStateProvider), AuthState.authenticated);
      expect(failoverCalls, 0);
      verifyNever(knowledge.getKnowledgeList);
      verifyNever(() => knowledge.getKnowledgeDetail(any()));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('游客直接进入目录不请求元数据、全文或正文', (tester) async {
    final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedOut);
    final knowledgeList = _KnowledgeList();
    final knowledge = _Knowledge();
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
    when(() => instance.knowledge).thenReturn(knowledge);
    await _pumpList(tester, XboardServiceImpl(sdk: instance), guest: true);

    expect(find.text('请先登录', findRichText: true), findsOneWidget);
    verifyNever(knowledgeList.getKnowledgeList);
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(() => knowledge.getKnowledgeDetail(any()));
    expect(tester.takeException(), isNull);
  });

  test('会话世代变化后晚到的轻量目录响应不能作为成功结果', () async {
    final instance = FakeXBoardSDK()..setupFor(XbScenario.loggedIn);
    final knowledgeList = _KnowledgeList();
    final knowledge = _Knowledge();
    final pending = Completer<List<sdk.KnowledgeItem>>();
    when(() => instance.knowledgeList).thenReturn(knowledgeList);
    when(() => instance.knowledge).thenReturn(knowledge);
    when(knowledgeList.getKnowledgeList).thenAnswer((_) => pending.future);
    final result = XboardServiceImpl(sdk: instance).getTutorials();

    when(() => instance.authSession).thenReturn(
      const sdk.AuthSessionSnapshot(
        revision: 2,
        state: sdk.AuthState.authenticated,
      ),
    );
    pending.complete(const [
      sdk.KnowledgeItem(
        id: 21,
        category: '官方客户端',
        title: '旧账号晚到的目录',
        updatedAt: 1791936000,
      ),
    ]);
    final response = await result;

    expect(response, isA<XbFailure<List<XbTutorial>>>());
    final failure = response as XbFailure<List<XbTutorial>>;
    expect(failure.error, isA<XbNetwork>());
    expect((failure.error as XbNetwork).kind, XbNetworkKind.cancelled);
    verify(knowledgeList.getKnowledgeList).called(1);
    verifyNever(knowledge.getKnowledgeList);
    verifyNever(() => knowledge.getKnowledgeDetail(any()));
  });

  testWidgets('目录请求失败后点击重试会重新请求并显示后台标题', (tester) async {
    final service = _Service();
    var calls = 0;
    when(service.getTutorials).thenAnswer((_) async {
      calls++;
      return calls == 1
          ? const XbFailure<List<XbTutorial>>(
              XbNetwork(XbNetworkKind.connectionFailed, '测试网络不可用'),
            )
          : XbResult.success([_tutorial()]);
    });
    await _pumpList(tester, service);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text(_listTitle), findsNothing);

    await tester.tap(find.text('重试'));
    await _finish(tester);
    expect(calls, 2);
    expect(find.text(_listTitle), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final state in _ListState.values) {
    testWidgets('${state.name}短目录可通过下拉刷新恢复，登录状态保持不变', (tester) async {
      final service = _Service();
      var calls = 0;
      when(service.getTutorials).thenAnswer((_) async {
        calls++;
        return calls == 1
            ? _listResponse(state)
            : XbResult.success([_tutorial(title: '下拉取得的新目录')]);
      });
      final container = await _pumpList(tester, service);
      _expectInitialListState(state);
      expect(calls, 1);

      await _pullList(tester);

      expect(calls, 2);
      expect(find.text('下拉取得的新目录'), findsOneWidget);
      expect(find.text('刷新前的目录'), findsNothing);
      expect(find.text('暂无使用教程', findRichText: true), findsNothing);
      expect(find.text(_failureTitle, findRichText: true), findsNothing);
      expect(find.text(_timeoutTitle, findRichText: true), findsNothing);
      expect(container.read(authStateProvider), AuthState.authenticated);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空目录刷新按钮与下拉共用请求，在途重复动作不再发起新请求', (tester) async {
    final service = _Service();
    final refreshing = Completer<XbResult<List<XbTutorial>>>();
    var calls = 0;
    when(service.getTutorials).thenAnswer((_) {
      calls++;
      return calls == 1
          ? Future.value(const XbSuccess(<XbTutorial>[]))
          : refreshing.future;
    });
    await _pumpList(tester, service);
    _expectListState('暂无使用教程', _emptyDescription, '刷新');

    // 两次点按之间不 pump，验证旧按钮尚未重建的事件窗口也不能重复请求。
    await tester.tap(find.text('刷新'));
    await tester.tap(find.text('刷新'));
    await _finish(tester);
    expect(calls, 2);
    expect(find.text('刷新'), findsNothing);
    await _pullList(tester);
    expect(calls, 2);

    refreshing.complete(XbResult.success([_tutorial(title: '按钮刷新的目录')]));
    await _finish(tester);
    expect(find.text('按钮刷新的目录'), findsOneWidget);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('教程目录默认最多等待20秒，整体截止后显示可重试超时态', (tester) async {
    final service = _Service();
    final pending = Completer<XbResult<List<XbTutorial>>>();
    var calls = 0;
    when(service.getTutorials).thenAnswer((_) {
      calls++;
      return pending.future;
    });
    final container = await _pumpList(tester, service);
    expect(
      container.read(tutorialListTimeoutProvider),
      const Duration(seconds: 20),
    );

    // _pumpList 已推进800ms；19.8秒时仍在等待，20秒后必须结束等待。
    await tester.pump(const Duration(seconds: 19));
    expect(find.text(_timeoutTitle, findRichText: true), findsNothing);
    expect(calls, 1, reason: '整体等待期间不通过provider后台重试增加请求');
    await tester.pump(const Duration(milliseconds: 201));
    await _finish(tester);

    _expectListState(_timeoutTitle, _timeoutDescription, '重试');
    expect(container.read(tutorialsProvider).error, isA<XbNetwork>());
    final error = container.read(tutorialsProvider).error! as XbNetwork;
    expect(error.kind, XbNetworkKind.timeout);
    expect(container.read(authStateProvider), AuthState.authenticated);
    expect(calls, 1);
    pending.complete(XbResult.success([_tutorial(title: '截止后晚到的目录')]));
    await _finish(tester);
    _expectListState(_timeoutTitle, _timeoutDescription, '重试');
    expect(find.text('截止后晚到的目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final lateError in [false, true]) {
    testWidgets('目录超时后晚到${lateError ? '错误' : '成功'}不覆盖重试取得的新目录', (tester) async {
      final service = _Service();
      final pending = Completer<XbResult<List<XbTutorial>>>();
      var calls = 0;
      when(service.getTutorials).thenAnswer((_) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(XbResult.success([_tutorial(title: '重试取得的新目录')]));
      });
      final container = await _pumpList(
        tester,
        service,
        listTimeout: const Duration(seconds: 2),
      );
      await tester.pump(const Duration(seconds: 2));
      await _finish(tester);
      _expectListState(_timeoutTitle, _timeoutDescription, '重试');
      expect(calls, 1);

      await tester.tap(find.text('重试'));
      await _finish(tester);
      expect(calls, 2);
      expect(find.text('重试取得的新目录'), findsOneWidget);
      if (lateError) {
        pending.completeError(StateError('截止后晚到的错误'));
      } else {
        pending.complete(XbResult.success([_tutorial(title: '旧请求晚到的目录')]));
      }
      await _finish(tester);

      expect(find.text('重试取得的新目录'), findsOneWidget);
      expect(find.text('旧请求晚到的目录'), findsNothing);
      expect(find.text(_timeoutTitle, findRichText: true), findsNothing);
      expect(find.text(_failureTitle, findRichText: true), findsNothing);
      expect(container.read(authStateProvider), AuthState.authenticated);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('退出隐藏在途目录，重新登录后旧目录不能覆盖新账号结果', (tester) async {
    final service = _Service();
    final previous = Completer<XbResult<List<XbTutorial>>>();
    var calls = 0;
    when(service.getTutorials).thenAnswer((_) {
      calls++;
      return calls == 1
          ? previous.future
          : Future.value(XbResult.success([_tutorial(title: '账号B的目录')]));
    });
    final container = await _pumpList(tester, service);
    expect(calls, 1);

    container.read(authStateProvider.notifier).markUnauthenticated();
    await _finish(tester);
    expect(find.text('请先登录', findRichText: true), findsOneWidget);
    expect(calls, 1);
    container.read(authStateProvider.notifier).markAuthenticated();
    await _finish(tester);
    expect(find.text('账号B的目录'), findsOneWidget);
    expect(calls, 2);
    previous.complete(XbResult.success([_tutorial(title: '账号A晚到的目录')]));
    await _finish(tester);

    expect(find.text('账号B的目录'), findsOneWidget);
    expect(find.text('账号A晚到的目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录认证错误保留登录过期提示，不混成普通失败或空态', (tester) async {
    final service = _Service();
    when(service.getTutorials).thenAnswer(
      (_) async => const XbFailure<List<XbTutorial>>(XbUnauthorized('受控401')),
    );
    await _pumpList(tester, service);

    expect(find.text('登录已过期，请重新登录', findRichText: true), findsOneWidget);
    expect(find.text('登录后查看使用教程。', findRichText: true), findsOneWidget);
    expect(find.text(_failureTitle, findRichText: true), findsNothing);
    expect(find.text('暂无使用教程', findRichText: true), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final state in [
    _ListState.empty,
    _ListState.failure,
    _ListState.timeout,
  ]) {
    for (final width in [320.0, 1280.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '${state.name}状态在${width.toInt()}px/${brightness.name}可见且无溢出',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 800);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final service = _Service();
            when(
              service.getTutorials,
            ).thenAnswer((_) async => _listResponse(state));
            await _pumpList(tester, service, brightness: brightness);
            _expectInitialListState(state);

            final action = find.text(state == _ListState.empty ? '刷新' : '重试');
            expect(action.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('详情请求失败后点重试，重新取正文并创建阅读器', (tester) async {
    final f = _DetailFixture();
    var calls = 0;
    when(() => f.service.getTutorialDetail(21)).thenAnswer((_) async {
      calls++;
      return calls == 1
          ? const XbFailure<XbTutorialDetail>(
              XbNetwork(XbNetworkKind.connectionFailed, '测试网络不可用'),
            )
          : XbResult.success(_detail('<h1>服务端正文自己的标题</h1>'));
    });
    await f.pump(tester);
    expect(f.inputs, isEmpty);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await _finish(tester);
    expect(calls, 2);
    expect(find.byKey(const Key('native-reader-placeholder')), findsOneWidget);
    expect(f.inputs.last.html, contains('服务端正文自己的标题'));
    expect(find.text('后台文章标题'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('刷新教程重新请求API正文，不只重新加载旧HTML', (tester) async {
    final f = _DetailFixture();
    final refreshed = Completer<XbResult<XbTutorialDetail>>();
    var calls = 0;
    when(() => f.service.getTutorialDetail(21)).thenAnswer((_) {
      calls++;
      return calls == 1
          ? Future.value(XbResult.success(_detail('<p>旧版教程正文</p>')))
          : refreshed.future;
    });
    await f.pump(tester);
    expect(calls, 1);
    expect(f.inputs.last.html, contains('旧版教程正文'));

    await tester.tap(find.byTooltip('刷新教程'));
    await _finish(tester);
    expect(calls, 2);
    final refreshButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '刷新教程',
    );
    expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);
    await tester.tap(find.byTooltip('刷新教程'));
    await _finish(tester);
    expect(calls, 2, reason: '正文请求在途时重复点击不能发起新请求');
    refreshed.complete(XbResult.success(_detail('<p>新版教程正文</p>')));
    await _finish(tester);
    expect(tester.widget<IconButton>(refreshButton).onPressed, isNotNull);
    expect(f.inputs.last.html, contains('新版教程正文'));
    expect(f.inputs.last.html, isNot(contains('旧版教程正文')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('游客直接进入详情不请求受保护接口，也不创建原生阅读器', (tester) async {
    final f = _DetailFixture();
    await f.pump(tester, guest: true);
    verifyNever(() => f.service.getTutorialDetail(any()));
    expect(f.inputs, isEmpty);
    expect(find.byKey(const Key('native-reader-placeholder')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出立即销毁旧阅读器；重新登录重新取正文', (tester) async {
    final f = _DetailFixture();
    var calls = 0;
    when(() => f.service.getTutorialDetail(21)).thenAnswer((_) async {
      calls++;
      return XbResult.success(
        _detail(calls == 1 ? '<p>账号A教程正文</p>' : '<p>账号B教程正文</p>'),
      );
    });
    await f.pump(tester);
    expect(f.inputs.last.html, contains('账号A教程正文'));

    f.container.read(authStateProvider.notifier).markUnauthenticated();
    await tester.pump();
    expect(find.byKey(const Key('native-reader-placeholder')), findsNothing);
    expect(f.nativeDisposals, 1, reason: '退出时不能由淡出动画继续保留旧正文');

    f.container.read(authStateProvider.notifier).markAuthenticated();
    await _finish(tester);
    expect(calls, 2);
    expect(f.inputs.last.html, contains('账号B教程正文'));
    expect(f.inputs.last.html, isNot(contains('账号A教程正文')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出后晚到的详情响应不能创建阅读器或复活旧正文', (tester) async {
    final f = _DetailFixture();
    final pending = Completer<XbResult<XbTutorialDetail>>();
    when(
      () => f.service.getTutorialDetail(21),
    ).thenAnswer((_) => pending.future);
    await f.pump(tester);
    expect(f.inputs, isEmpty);

    f.container.read(authStateProvider.notifier).markUnauthenticated();
    await tester.pump();
    pending.complete(XbResult.success(_detail('<p>旧账号晚到的正文</p>')));
    await _finish(tester);
    expect(f.inputs, isEmpty);
    expect(find.byKey(const Key('native-reader-placeholder')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
