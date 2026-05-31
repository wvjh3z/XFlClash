/// W6.5 — IpMirrorPrewarmer fire-and-forget + 节流 + justLoggedIn 绕过（F386 / Property 17）。

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/ip_mirror_prewarmer.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;
  setUp(() => service = _MockService());

  IpMirrorConfigUi cfg({bool enabled = true, List<String>? urls}) => IpMirrorConfigUi(
        enabled: enabled,
        urls: urls ?? ['https://m1', 'https://m2'],
        throttle: const Duration(minutes: 5),
        fetchTimeout: const Duration(seconds: 3),
      );

  test('成功 → fireAllMirrors 被调（fire-and-forget）', () async {
    when(() => service.fetchMirrorList())
        .thenAnswer((_) async => XbResult.success(cfg()));
    when(() => service.fireAllMirrors(any())).thenReturn(null);
    final pw = IpMirrorPrewarmer(service: service);
    await pw.prewarm(justLoggedIn: true);
    verify(() => service.fireAllMirrors(['https://m1', 'https://m2'])).called(1);
  });

  test('fetchMirrorList 失败 → 静默不 fire', () async {
    when(() => service.fetchMirrorList()).thenAnswer(
        (_) async => XbResult.failure(XbDomainError.network(XbNetworkKind.timeout, 't')));
    final pw = IpMirrorPrewarmer(service: service);
    await pw.prewarm();
    verifyNever(() => service.fireAllMirrors(any()));
  });

  test('disabled / 空 urls → 不 fire', () async {
    when(() => service.fetchMirrorList())
        .thenAnswer((_) async => XbResult.success(cfg(enabled: false)));
    final pw = IpMirrorPrewarmer(service: service);
    await pw.prewarm(justLoggedIn: true);
    verifyNever(() => service.fireAllMirrors(any()));
  });

  test('节流：5 分钟内第二次跳过（非 justLoggedIn）', () async {
    when(() => service.fetchMirrorList())
        .thenAnswer((_) async => XbResult.success(cfg()));
    when(() => service.fireAllMirrors(any())).thenReturn(null);
    var t = DateTime(2026, 1, 1, 12, 0, 0);
    final pw = IpMirrorPrewarmer(service: service, clock: () => t);
    await pw.prewarm(justLoggedIn: true); // 首次（绕节流）fire
    t = t.add(const Duration(minutes: 2)); // 2 分钟后
    await pw.prewarm(); // 节流内
    verify(() => service.fireAllMirrors(any())).called(1); // 只 fire 1 次
  });

  test('节流：超过 5 分钟可再次 fire', () async {
    when(() => service.fetchMirrorList())
        .thenAnswer((_) async => XbResult.success(cfg()));
    when(() => service.fireAllMirrors(any())).thenReturn(null);
    var t = DateTime(2026, 1, 1, 12, 0, 0);
    final pw = IpMirrorPrewarmer(service: service, clock: () => t);
    await pw.prewarm(justLoggedIn: true);
    t = t.add(const Duration(minutes: 6));
    await pw.prewarm();
    verify(() => service.fireAllMirrors(any())).called(2);
  });
}
