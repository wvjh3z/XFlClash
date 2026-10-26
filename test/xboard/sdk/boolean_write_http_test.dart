import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';

void main() {
  for (final action in ['withdraw', 'transfer', 'forgot', 'code', 'register']) {
    for (final response in [
      'rejected',
      'false',
      'missing',
      'accepted',
      'acceptedObjectMetadata',
      'falseObjectMetadata',
      'missingObjectMetadata',
      'rejectedObjectMetadata',
    ]) {
      final baseResponse = response.replaceAll('ObjectMetadata', '');
      test('$action requires explicit acknowledgement: $response', () async {
        SharedPreferences.setMockInitialValues({});
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var writes = 0;
        server.listen((r) async {
          await r.drain<void>();
          r.response.headers.contentType = ContentType.json;
          Object? data;
          if (r.method == 'POST') {
            writes++;
            data = switch (baseResponse) {
              'rejected' =>
                true, // Explicit failure must win over contradictory data.
              'false' => false,
              'accepted' =>
                action == 'register' ? {'auth_data': 'fixture-token'} : true,
              _ => null,
            };
          } else {
            data = r.uri.path.endsWith('/invite/fetch')
                ? {'codes': [], 'stat': []}
                : {'email': 'fixture@example.test', 'uuid': 'fixture'};
          }
          r.response.write(
            jsonEncode({
              'status': r.method == 'POST' && baseResponse == 'rejected'
                  ? 'fail'
                  : 'success',
              'message': response.endsWith('ObjectMetadata')
                  ? {'detail': 'fixture'}
                  : 'fixture response',
              'code': response.endsWith('ObjectMetadata') ? ['invalid'] : 200,
              'data': data,
            }),
          );
          await r.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        final instance = sdk.XBoardSDK.instance;
        await instance.initialize(base, customStorage: MemoryTokenStorage());
        addTearDown(instance.dispose);
        instance.httpService.configureEndpointRecovery(
          candidates: () => [base],
          onSuccess: (_) {},
        );
        final service = XboardServiceImpl(sdk: instance);
        final result = switch (action) {
          'withdraw' => await service.withdrawCommission(
            method: 'bank',
            account: 'fixture',
          ),
          'transfer' => await service.transferCommissionToBalance(1),
          'forgot' => await service.forgotPassword(
            'fixture@example.test',
            '123456',
            'password-fixture',
          ),
          'code' => await service.sendEmailVerifyCode('fixture@example.test'),
          _ => await service.register(
            'fixture@example.test',
            'password-fixture',
          ),
        };
        if (baseResponse == 'accepted') {
          expect((result as XbSuccess<bool>).data, isTrue);
        } else {
          expect(
            (result as XbFailure).error,
            baseResponse == 'rejected'
                ? isA<XbBusiness>()
                : isA<XbUnconfirmed>(),
          );
        }
        expect(writes, 1);
      });
    }
  }
  for (final mode in [
    'empty',
    'malformed',
    'disabled',
    'rate',
    'rejected',
    'usable',
    'saveUnknown',
    'saveMalformed',
    'concurrent',
  ]) {
    test('invite stage preserves save result: $mode', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var saves = 0;
      server.listen((r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType.json;
        final save = r.uri.path.endsWith('/save');
        if (save) saves++;
        if (!save && mode == 'rate') r.response.statusCode = 429;
        if (save && mode == 'saveUnknown') r.response.statusCode = 405;
        final code = {
          'user_id': 1,
          'code': 'fixture',
          'pv': 0,
          'status': ![
            'usable',
            'saveUnknown',
            'saveMalformed',
            'concurrent',
          ].contains(mode),
          'created_at': 1,
          'updated_at': 1,
        };
        final data = save
            ? (mode == 'saveMalformed' ? null : true)
            : mode == 'malformed'
            ? 'invalid'
            : {
                'codes':
                    [
                      'disabled',
                      'usable',
                      'saveUnknown',
                      'saveMalformed',
                      'concurrent',
                    ].contains(mode)
                    ? [code]
                    : [],
                'stat': [],
              };
        r.response.write(
          jsonEncode({
            'status': save && mode == 'rejected' ? 'fail' : 'success',
            'message': 'fixture refusal',
            'data': data,
          }),
        );
        await r.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final instance = sdk.XBoardSDK.instance;
      await instance.initialize(base, customStorage: MemoryTokenStorage());
      addTearDown(instance.dispose);
      instance.httpService.configureEndpointRecovery(
        candidates: () => [base],
        onSuccess: (_) {},
      );
      if (mode == 'concurrent') {
        final results = await Future.wait([
          instance.invite.generateInviteCode(),
          instance.invite.generateInviteCode(),
        ]);
        expect(results, ['fixture', 'fixture']);
        expect(saves, 1);
        return;
      }
      final service = XboardServiceImpl(sdk: instance);
      final first = await service.generateInviteCode();
      if ([
        'usable',
        'saveUnknown',
        'saveMalformed',
        'concurrent',
      ].contains(mode)) {
        expect((first as XbSuccess<String>).data, 'fixture');
        if (mode != 'usable') {
          await service.generateInviteCode();
          expect(saves, 1);
        }
      } else {
        expect(first, isA<XbFailure>());
        await service.generateInviteCode();
        expect(saves, mode == 'rejected' ? 2 : 1);
      }
    });
  }
  test(
    'late invitation from account A cannot clear account B flight',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final aStarted = Completer<void>();
      final bStarted = Completer<void>();
      final aRelease = Completer<void>();
      final bRelease = Completer<void>();
      var aSaves = 0;
      var bSaves = 0;
      var bFetches = 0;
      server.listen((r) async {
        await r.drain<void>();
        final accountA = r.headers.value('authorization') == 'Bearer fixture-a';
        final save = r.uri.path.endsWith('/save');
        if (save) {
          if (accountA) {
            aSaves++;
            aStarted.complete();
            await aRelease.future;
          } else {
            bSaves++;
            bStarted.complete();
            await bRelease.future;
          }
        } else if (!accountA) {
          bFetches++;
        }
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'status': 'success',
            'data': save
                ? true
                : {
                    'codes': [
                      {
                        'user_id': 1,
                        'code': 'code-b',
                        'pv': 0,
                        'status': false,
                        'created_at': 1,
                        'updated_at': 1,
                      },
                    ],
                    'stat': [],
                  },
          }),
        );
        await r.response.close();
      });
      final instance = sdk.XBoardSDK.instance;
      await instance.initialize(
        'http://127.0.0.1:${server.port}',
        customStorage: MemoryTokenStorage(),
      );
      addTearDown(instance.dispose);
      await instance.saveToken('fixture-a');
      final api = instance
          .invite; // Intentionally retain the same adapter across accounts.
      final old = api.generateInviteCode();
      final oldAssertion = expectLater(
        old,
        throwsA(isA<sdk.NetworkException>()),
      );
      await aStarted.future.timeout(const Duration(seconds: 5));
      await instance.saveToken('fixture-b');
      final next = api.generateInviteCode();
      await bStarted.future.timeout(const Duration(seconds: 5));
      aRelease.complete();
      await oldAssertion;
      final concurrent = api.generateInviteCode();
      bRelease.complete();
      expect(await Future.wait([next, concurrent]), ['code-b', 'code-b']);
      expect(aSaves, 1);
      expect(bSaves, 1);
      expect(bFetches, 1);
    },
  );
}
