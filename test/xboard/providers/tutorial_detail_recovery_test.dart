import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_tutorial.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/tutorial_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';

class _Sdk extends Mock implements sdk.XBoardSDK {}

class _Config implements sdk.ConfigApi {
  _Config(this.delegate);
  final sdk.ConfigApi delegate;
  late Future<sdk.ConfigModel> pending;
  @override
  Future<sdk.ConfigModel> getConfig() => pending = delegate.getConfig();
}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _Service extends XboardServiceImpl {
  _Service({required super.sdk});
  late Future<XbResult<XbTutorialDetail>> pending;
  @override
  Future<XbResult<XbTutorialDetail>> getTutorialDetailForRequest(
    int id, {
    required bool Function() isActive,
  }) => pending = super.getTutorialDetailForRequest(id, isActive: isActive);
}

void main() {
  for (final brand in ['omo', 'ds']) {
    for (final scenario in [
      'dispose',
      'timeout',
      'timeoutWhileLoading',
      'articleFailure',
      'success',
    ]) {
      test('$brand detail recovery lifetime: $scenario', () async {
        SharedPreferences.setMockInitialValues({});
        XboardConfig.resetForTest();
        final seen = <String>[];
        final selected = <String>[];
        final began = Completer<void>();
        final release = Completer<void>();
        final articleRelease = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final auxiliary =
            scenario.startsWith('timeout') || scenario == 'articleFailure';
        server.listen((request) async {
          final path = request.uri.path;
          seen.add(path);
          await request.drain<void>();
          final config = path.endsWith('/comm/config');
          final target = auxiliary ? config : !config;
          if (target && path.startsWith('/$brand/a/')) {
            began.complete();
            await release.future;
            request.response.statusCode = 405;
            request.response.write('<html>fixture gateway</html>');
          } else if (scenario == 'articleFailure' && !config) {
            request.response.statusCode = 404;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'message': 'article missing'}));
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'status': 'success',
                'data': config
                    ? {
                        'app_name': 'fixture',
                        'app_url': 'https://fixture.invalid',
                      }
                    : {
                        'id': 1,
                        'title': 'fixture',
                        'body': 'fixture',
                        'category': '官方客户端',
                        'updated_at': 1,
                      },
              }),
            );
          }
          if (scenario == 'timeoutWhileLoading' && !config) {
            await articleRelease.future;
          }
          await request.response.close();
        });
        final origin = 'http://127.0.0.1:${server.port}/$brand';
        final real = sdk.XBoardSDK.instance;
        await real.initialize('$origin/a', customStorage: MemoryTokenStorage());
        addTearDown(real.dispose);
        real.httpService.configureEndpointRecovery(
          candidates: () => ['$origin/a', '$origin/b'],
          onSuccess: selected.add,
        );
        // Observe completion without replacing the actual HTTP/recovery chain.
        final config = _Config(real.config);
        final proxy = _Sdk();
        when(() => proxy.httpService).thenReturn(real.httpService);
        when(() => proxy.authSession).thenAnswer((_) => real.authSession);
        when(() => proxy.config).thenReturn(config);
        when(() => proxy.knowledge).thenReturn(real.knowledge);
        final service = _Service(sdk: proxy);
        final container = ProviderContainer(
          overrides: [
            xboardServiceProvider.overrideWithValue(service),
            authStateProvider.overrideWith(() => _Auth()),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          tutorialDetailProvider(1),
          (_, next) {},
        );
        await began.future.timeout(const Duration(seconds: 5));
        if (scenario == 'dispose') {
          // Settle the independent config success before isolating article disposal.
          await config.pending;
          subscription.close();
          await container.pump();
          expect(container.exists(tutorialDetailProvider(1)), isFalse);
        } else if (scenario == 'timeoutWhileLoading') {
          // The 3-second production timer was installed before HTTP began.
          // Keep the article pending so its outer scope cannot mask expiry.
          await Future<void>.delayed(const Duration(seconds: 3));
          release.complete();
          await expectLater(config.pending, throwsA(isA<Exception>()));
          articleRelease.complete();
        } else if (scenario == 'timeout') {
          expect(
            await service.pending.timeout(const Duration(seconds: 4)),
            isA<XbSuccess<XbTutorialDetail>>(),
          );
        } else if (scenario == 'articleFailure') {
          expect(await service.pending, isA<XbFailure<XbTutorialDetail>>());
        }
        if (!release.isCompleted) release.complete();
        final result = await service.pending.timeout(
          const Duration(seconds: 5),
        );
        if (auxiliary) {
          await expectLater(config.pending, throwsA(isA<Exception>()));
        } else {
          await config.pending;
          expect(
            result,
            scenario == 'success'
                ? isA<XbSuccess<XbTutorialDetail>>()
                : isA<XbFailure<XbTutorialDetail>>(),
          );
        }
        expect(
          seen.where((path) => path.startsWith('/$brand/b/')).length,
          scenario == 'success' ? 1 : 0,
        );
        expect(selected.contains('$origin/b'), scenario == 'success');
      });
    }
  }
}
