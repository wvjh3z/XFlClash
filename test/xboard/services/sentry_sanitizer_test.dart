import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:fl_clash/xboard/services/sentry_sanitizer.dart';

void main() {
  group('SentrySanitizer application data', () {
    test(
      'nested generic maps and lists redact keys without mutating input',
      () {
        final input = <String, dynamic>{
          'items': [
            <dynamic, dynamic>{'access_token': 'secret', 'count': 2},
            {
              'headers': {
                'AUTHORIZATION': 'Bearer abc',
                'Set-Cookie': 'session=abc',
              },
            },
            [
              {'auth_data': 'secret', 'password': 'quoted with spaces'},
              'user test@example.com',
            ],
          ],
          'plan': 'Pro',
        };
        final clean = SentrySanitizer.scrubData(input);
        expect((clean['items'] as List)[0], {
          'access_token': '***',
          'count': 2,
        });
        expect((clean['items'] as List)[1], {
          'headers': {'AUTHORIZATION': '***', 'Set-Cookie': '***'},
        });
        expect((input['items'] as List)[0]['access_token'], 'secret');
        expect(clean['plan'], 'Pro');
        expect(clean.toString(), isNot(contains('test@example.com')));
        expect(clean.toString(), isNot(contains('quoted with spaces')));
      },
    );

    test(
      'Bearer, JSON/plain credentials, email and account UUID redact in text',
      () {
        final clean = SentrySanitizer.scrubText(
          'Bearer eyJhbGci.abc_xyz-123/+== '
          'password=plain auth_data=xyz '
          '{"refresh_token":"refresh", "password":"a password with spaces"} '
          'user=test@example.com uuid=123e4567-e89b-12d3-a456-426614174000',
        );
        for (final secret in [
          'eyJhbGci',
          'plain',
          'xyz',
          'refresh"',
          'a password with spaces',
          'test@example.com',
          '123e4567-e89b-12d3-a456-426614174000',
        ]) {
          expect(clean, isNot(contains(secret)), reason: clean);
        }
        expect(clean, contains('Bearer ***'));
      },
    );

    test('URLs drop every query/fragment value and URL user credentials', () {
      final clean = SentrySanitizer.scrubText(
        'GET https://user:pass@example.com/api?auth%5Fdata=abc&custom=opaque#token=fragment',
      );
      expect(clean, contains('example.com/api'));
      for (final secret in ['user:pass', 'abc', 'opaque', 'fragment']) {
        expect(clean, isNot(contains(secret)), reason: clean);
      }
    });

    test(
      'safe diagnostics, numbers, booleans and null retain their values',
      () {
        final clean = SentrySanitizer.scrubData({
          'status_code': 503,
          'reason': 'connection timed out',
          'attempt': 3,
          'auth.state': 'authenticated',
          'online': false,
          'optional': null,
        });
        expect(clean, {
          'status_code': 503,
          'reason': 'connection timed out',
          'attempt': 3,
          'auth.state': 'authenticated',
          'online': false,
          'optional': null,
        });
      },
    );
  });

  test(
    'event filtering keeps symbolication identities/frames and scrubs payloads',
    () {
      const debugId = '123e4567-e89b-12d3-a456-426614174000';
      final event = SentryEvent.fromJson({
        'event_id': '12345678901234567890123456789012',
        'level': 'fatal',
        'release': 'brand_a@1.0+14',
        'environment': 'brand_a',
        'message': {'formatted': 'token=secret native mutex failed'},
        'user': {
          'id': 'account-id',
          'email': 'test@example.com',
          'ip_address': '1.2.3.4',
        },
        'contexts': {
          'api': {
            'data': [
              {'accessToken': 'secret'},
            ],
            'code': 503,
          },
        },
        'tags': {
          'endpoint.current': 'https://example.com/api?key=private',
          'auth.state': 'authenticated',
        },
        'request': {
          'url': 'https://example.com/api?token=secret',
          'headers': {
            'Authorization': 'Bearer secret',
            'Content-Type': 'application/json',
          },
          'data': {'password': 'secret'},
        },
        'breadcrumbs': [
          {
            'message': 'test@example.com',
            'data': {'refresh_token': 'secret'},
          },
        ],
        'exception': {
          'values': [
            {
              'type': 'EXCEPTION_ACCESS_VIOLATION_READ',
              'value': 'token=secret',
              'stacktrace': {
                'registers': {'rip': '0x7ffbd5f62c10'},
                'frames': [
                  {
                    'function': 'mtx_do_lock',
                    'package': 'MSVCP140.dll',
                    'instruction_addr': '0x7ffbd5f62c10',
                    'filename': 'mutex.cpp',
                    'abs_path':
                        'https://example.com/source.cpp?token=frame-secret',
                    'context_line': 'password=context-secret',
                    'pre_context': ['token=pre-secret'],
                    'post_context': ['email=post@example.com'],
                    'lineno': 103,
                    'vars': {'token': 'secret', 'attempt': 1},
                  },
                ],
              },
            },
          ],
        },
        'threads': {
          'values': [
            {
              'id': 12,
              'stacktrace': {
                'frames': [
                  {'function': 'render', 'instruction_addr': '0x1234'},
                ],
              },
            },
          ],
        },
        'debug_meta': {
          'images': [
            {
              'type': 'pe',
              'debug_id': debugId,
              'code_id': '6ad092ba',
              'debug_file': 'plugin.pdb',
              'code_file': 'https://example.com/plugin.dll?token=image-secret',
              'image_addr': '0x7ffbad6e0000',
              'extra_payload': {
                'uuid': 'account-secret',
                'token': 'metadata-secret',
              },
            },
          ],
        },
      });
      // Construct the SDK model directly: its own 9.22.0 thread JSON parser
      // has a nested-stack regression, which the sanitizer must not repeat.
      event.threads = [
        SentryThread(
          id: 12,
          stacktrace: SentryStackTrace(
            frames: [
              SentryStackFrame(function: 'render', instructionAddr: '0x1234'),
            ],
          ),
        ),
      ];
      final clean = SentrySanitizer.scrubEvent(event);
      final json = clean.toJson();
      expect(clean.debugMeta!.images.single.debugId, debugId);
      expect(clean.debugMeta!.images.single.imageAddr, '0x7ffbad6e0000');
      expect(clean.debugMeta!.images.single.debugFile, 'plugin.pdb');
      final frame = clean.exceptions!.single.stackTrace!.frames.single;
      expect(frame.function, 'mtx_do_lock');
      expect(frame.instructionAddr, '0x7ffbd5f62c10');
      expect(frame.fileName, 'mutex.cpp');
      expect(frame.lineNo, 103);
      expect(frame.vars['token'], '***');
      expect(frame.vars['attempt'], 1);
      expect(
        clean.threads!.single.stacktrace!.frames.single.function,
        'render',
      );
      expect(clean.level, SentryLevel.fatal);
      expect(clean.release, event.release);
      expect(clean.environment, event.environment);
      expect(clean.user, isNull);
      expect(json.toString(), isNot(contains('secret')));
      expect(json.toString(), isNot(contains('test@example.com')));
      expect(json.toString(), isNot(contains('private')));
      expect(json.toString(), isNot(contains('post@example.com')));
      expect(event.user!.email, 'test@example.com');
    },
  );

  test(
    'breadcrumb filtering keeps time/category/status and filters URL/data/text',
    () {
      final breadcrumb = Breadcrumb(
        timestamp: DateTime.utc(2026, 10, 15),
        category: 'http',
        level: SentryLevel.warning,
        message: 'request failed for test@example.com',
        data: {
          'url': 'https://example.com/api?key=secret',
          'status_code': 401,
          'items': [
            {'auth_data': 'secret'},
          ],
        },
      );
      final clean = SentrySanitizer.scrubBreadcrumb(breadcrumb);
      expect(clean.timestamp, breadcrumb.timestamp);
      expect(clean.category, 'http');
      expect(clean.level, SentryLevel.warning);
      expect(clean.data!['status_code'], 401);
      expect(clean.toJson().toString(), isNot(contains('secret')));
      expect(clean.message, isNot(contains('test@example.com')));
    },
  );
}
