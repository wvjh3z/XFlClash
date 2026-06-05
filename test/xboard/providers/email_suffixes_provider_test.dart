/// W0.2 — emailSuffixesProvider fail-open 降级单测（form-a R5.6）。
///
/// 反腐层成功 → 透传后缀列表；反腐层失败 → `const []`（不阻塞注册，F208/fail-open）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;

  setUp(() => service = _MockService());

  ProviderContainer makeContainer() => ProviderContainer(
        overrides: [xboardServiceProvider.overrideWithValue(service)],
      );

  test('反腐层成功 → 透传后缀列表', () async {
    when(() => service.getEmailSuffixes())
        .thenAnswer((_) async => XbResult.success(const ['gmail.com', 'qq.com']));
    final container = makeContainer();
    addTearDown(container.dispose);
    final suffixes = await container.read(emailSuffixesProvider.future);
    expect(suffixes, ['gmail.com', 'qq.com']);
  });

  test('反腐层失败 → fail-open 返回空列表（不阻塞注册）', () async {
    when(() => service.getEmailSuffixes()).thenAnswer(
        (_) async => XbResult.failure(XbDomainError.unexpected('getEmailSuffixes', 'boom')));
    final container = makeContainer();
    addTearDown(container.dispose);
    final suffixes = await container.read(emailSuffixesProvider.future);
    expect(suffixes, isEmpty);
  });
}
