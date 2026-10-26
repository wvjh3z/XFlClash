import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';

class _ObservedService extends XboardServiceImpl {
  _ObservedService({required super.sdk});
  late Future<void> settled;
  @override
  Future<T> withInviteRequestValidity<T>(
    bool Function() active,
    Future<T> Function() body,
  ) {
    final pending = super.withInviteRequestValidity(active, body);
    settled = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }
}

void main() {
  for (final brand in ['omo', 'ds']) {
    for (final phase in ['initial', 'queued', 'dispatched', 'confirmation']) {
      test(
        '$brand invite page disposal at $phase prevents subsequent work',
        () async {
          SharedPreferences.setMockInitialValues({});
          final began = Completer<void>();
          final release = Completer<void>();
          final userReadBegan = Completer<void>();
          var gated = false;
          var saves = 0;
          final requests = <String>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((r) async {
            await r.drain<void>();
            requests.add(r.uri.path);
            final save = r.uri.path.endsWith('/save');
            final fetch = r.uri.path.endsWith('/invite/fetch');
            if (!save && !fetch && !userReadBegan.isCompleted) {
              userReadBegan.complete();
            }
            if (save) saves++;
            final shouldGate =
                (phase == 'initial' && fetch && saves == 0) ||
                (phase == 'dispatched' && save) ||
                (phase == 'confirmation' && fetch && saves > 0);
            if (shouldGate && !gated) {
              gated = true;
              began.complete();
              await release.future;
            }
            final code = {
              'user_id': 1,
              'code': 'UNUSED',
              'pv': 0,
              'status': false,
              'created_at': 1,
              'updated_at': 1,
            };
            final data = save
                ? true
                : fetch
                ? {
                    'codes': saves > 0 ? [code] : [],
                    'stat': [],
                  }
                : {'email': 'fixture@example.test', 'uuid': 'fixture'};
            r.response.headers.contentType = ContentType.json;
            r.response.write(jsonEncode({'status': 'success', 'data': data}));
            await r.response.close();
          });
          final base = 'http://127.0.0.1:${server.port}/$brand';
          final instance = sdk.XBoardSDK.instance;
          await instance.initialize(base, customStorage: MemoryTokenStorage());
          addTearDown(instance.dispose);
          await instance.saveToken('fixture-auth');
          instance.httpService.configureEndpointRecovery(
            candidates: () => [base],
            onSuccess: (_) {},
          );
          if (phase == 'queued') {
            // Test-only access gates the real asynchronous dispatch pipeline.
            // ignore: deprecated_member_use
            instance.httpService.dio.interceptors.insert(
              0,
              InterceptorsWrapper(
                onRequest: (o, h) async {
                  if (o.path.endsWith('/invite/save') && !gated) {
                    gated = true;
                    began.complete();
                    await release.future;
                  }
                  h.next(o);
                },
              ),
            );
          }
          final service = _ObservedService(sdk: instance);
          final container = ProviderContainer(
            overrides: [xboardServiceProvider.overrideWithValue(service)],
          );
          addTearDown(container.dispose);
          final subscription = container.listen(
            inviteInfoProvider,
            (_, next) {},
          );
          await began.future.timeout(const Duration(seconds: 5));
          if (phase == 'initial') {
            await userReadBegan.future.timeout(const Duration(seconds: 5));
          }
          subscription.close();
          await container.pump();
          expect(container.exists(inviteInfoProvider), isFalse);
          release.complete();
          await service.settled.timeout(const Duration(seconds: 5));
          expect(saves, phase == 'initial' || phase == 'queued' ? 0 : 1);
          expect(requests.length, switch (phase) {
            'initial' || 'queued' => 2,
            'dispatched' => 3,
            _ => 4,
          });
          final reopened = container.listen(inviteInfoProvider, (_, next) {});
          final info = await container
              .read(inviteInfoProvider.future)
              .timeout(const Duration(seconds: 5));
          expect(info.code, 'UNUSED');
          expect(saves, 1);
          reopened.close();
        },
      );
    }
  }
}
