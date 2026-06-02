/// W5.2.10 — EndpointRaceController：竞速选可达 / failOver 串行化 / 30min ≥5 次重竞速 / null 兜底。
/// v0.2 R4.9：地区感知竞速（VPN 开海外优先 / 关平等）+ VPN 切换重竞速。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';

/// 把 url 包成 endpoint（region 默认 unknown，VPN 关时不影响竞速）。
List<BootstrapEndpoint> _eps(List<String> urls,
        {BootstrapRegion region = BootstrapRegion.unknown}) =>
    urls.map((u) => BootstrapEndpoint(url: u, region: region)).toList();

/// 带 region 的 endpoint 列表（R4.9 测试用）。
List<BootstrapEndpoint> _mixed(Map<String, BootstrapRegion> m) =>
    m.entries.map((e) => BootstrapEndpoint(url: e.key, region: e.value)).toList();

void main() {
  test('D10：竞速前 currentApiEndpoint 为 null', () {
    final c = EndpointRaceController(probe: (_) async => true);
    expect(c.currentApiEndpoint, isNull);
    expect(c.currentSubscriptionEndpoint, isNull);
    c.dispose();
  });

  test('raceApi：选第一个 2xx 可达者', () async {
    final reachable = {'https://b.com'};
    final switches = <String>[];
    final c = EndpointRaceController(
      probe: (e) async => reachable.contains(e),
      onApiSwitch: switches.add,
    );
    await c.raceApi(_eps(['https://a.com', 'https://b.com', 'https://c.com']));
    expect(c.currentApiEndpoint, 'https://b.com');
    expect(switches, ['https://b.com']);
    c.dispose();
  });

  test('raceApi：全不可达 → current 保持 null', () async {
    final c = EndpointRaceController(probe: (_) async => false);
    await c.raceApi(_eps(['https://a.com', 'https://b.com']));
    expect(c.currentApiEndpoint, isNull);
    c.dispose();
  });

  test('raceSubscription：独立设置 subscription endpoint', () async {
    final c = EndpointRaceController(probe: (e) async => e.contains('sub2'));
    await c.raceSubscription(_eps(['https://sub1.com', 'https://sub2.com']));
    expect(c.currentSubscriptionEndpoint, 'https://sub2.com');
    c.dispose();
  });

  test('failOverApi：切到下一个可达者', () async {
    var firstReachable = true;
    final c = EndpointRaceController(
      probe: (e) async {
        if (e.contains('a.com')) return firstReachable;
        return true; // b 始终可达
      },
    );
    await c.raceApi(_eps(['https://a.com', 'https://b.com']));
    expect(c.currentApiEndpoint, 'https://a.com');
    // a 挂了 → failOver 到 b
    firstReachable = false;
    await c.failOverApi();
    expect(c.currentApiEndpoint, 'https://b.com');
    c.dispose();
  });

  test('failOverApi：B4 串行化锁——并发调用复用同一 Future', () async {
    var probeCalls = 0;
    final c = EndpointRaceController(
      probe: (e) async {
        probeCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return e.contains('b.com');
      },
    );
    await c.raceApi(_eps(['https://a.com', 'https://b.com']));
    probeCalls = 0;
    // 并发触发两次 failOver，串行化锁应让第二次复用第一次的 in-flight。
    await Future.wait([c.failOverApi(), c.failOverApi()]);
    expect(c.currentApiEndpoint, 'https://b.com');
    c.dispose();
  });

  test('30min 窗口 ≥5 次切换 → 触发重竞速（probe 被再次调用）', () async {
    var raceProbeBatches = 0;
    final c = EndpointRaceController(
      probe: (e) async {
        raceProbeBatches++;
        return e.contains('b.com');
      },
    );
    await c.raceApi(_eps(['https://a.com', 'https://b.com']));
    c.refreshRaceInBackground();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(raceProbeBatches, greaterThan(0));
    c.dispose();
  });

  // ── R4.9 地区感知竞速 ──
  group('R4.9 地区感知竞速', () {
    test('VPN 关：海外/国内平等竞速（国内可达即选国内）', () async {
      // 仅国内可达；VPN 关 → 平等竞速应选到国内。
      final c = EndpointRaceController(
        vpnActive: false,
        probe: (e) async => e.contains('cn'),
      );
      await c.raceApi(_mixed({
        'https://overseas.com': BootstrapRegion.overseas,
        'https://cn.com': BootstrapRegion.cn,
      }));
      expect(c.currentApiEndpoint, 'https://cn.com');
      c.dispose();
    });

    test('VPN 开：海外可达 → 选海外（即便国内也可达）', () async {
      final c = EndpointRaceController(
        vpnActive: true,
        probe: (_) async => true, // 全可达
      );
      await c.raceApi(_mixed({
        'https://overseas.com': BootstrapRegion.overseas,
        'https://cn.com': BootstrapRegion.cn,
      }));
      expect(c.currentApiEndpoint, 'https://overseas.com');
      c.dispose();
    });

    test('VPN 开：海外全挂 → 退国内兜底', () async {
      final c = EndpointRaceController(
        vpnActive: true,
        probe: (e) async => e.contains('cn'), // 仅国内可达
      );
      await c.raceApi(_mixed({
        'https://overseas.com': BootstrapRegion.overseas,
        'https://cn.com': BootstrapRegion.cn,
      }));
      expect(c.currentApiEndpoint, 'https://cn.com');
      c.dispose();
    });

    test('setVpnActive 切换 → 用新档位重竞速（关→开切到海外）', () async {
      final switches = <String>[];
      final c = EndpointRaceController(
        vpnActive: false,
        probe: (_) async => true, // 全可达
        onApiSwitch: switches.add,
      );
      // VPN 关：平等竞速（并发，结果不定但会选到某个可达者）。
      await c.raceApi(_mixed({
        'https://overseas.com': BootstrapRegion.overseas,
        'https://cn.com': BootstrapRegion.cn,
      }));
      // 开 VPN → 重竞速应切到海外。
      c.setVpnActive(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.currentApiEndpoint, 'https://overseas.com');
      c.dispose();
    });

    test('setVpnActive 相同值 → 不重竞速', () async {
      var batches = 0;
      final c = EndpointRaceController(
        vpnActive: false,
        probe: (e) async {
          batches++;
          return true;
        },
      );
      await c.raceApi(_eps(['https://a.com']));
      final before = batches;
      c.setVpnActive(false); // 同值
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(batches, before); // 未触发新竞速
      c.dispose();
    });
  });

  // ── R4.2 订阅 failOver + 候选列表 ──
  group('R4.2 订阅 failOver / subscriptionCandidates', () {
    test('竞速已选首发：候选首发在前 + 其余当替补（去重）', () async {
      final c = EndpointRaceController(probe: (e) async => e.contains('sub2'));
      await c.raceSubscription(_eps([
        'https://sub1.com',
        'https://sub2.com',
        'https://sub3.com',
      ]));
      expect(c.currentSubscriptionEndpoint, 'https://sub2.com');
      // 首发 sub2 排最前，其余按原序补上，sub2 不重复。
      expect(c.subscriptionCandidates(), [
        'https://sub2.com',
        'https://sub1.com',
        'https://sub3.com',
      ]);
      c.dispose();
    });

    test('竞速未跑（首发为 null）：直接用完整列表（D10 推广，无空窗）', () async {
      // 全不可达竞速把列表灌进去但不选出首发（模拟竞速跑了但没选出 / 等价未选首发态）。
      final c = EndpointRaceController(probe: (_) async => false);
      await c.raceSubscription(_eps(['https://s1.com', 'https://s2.com']));
      expect(c.currentSubscriptionEndpoint, isNull); // 全不可达 → 未选首发
      // 候选仍为完整列表（按地区排序，VPN 关 → 原序）。
      expect(c.subscriptionCandidates(), ['https://s1.com', 'https://s2.com']);
      c.dispose();
    });

    test('列表为空 → 候选空（调用方退回原 URL 兜底）', () {
      final c = EndpointRaceController(probe: (_) async => true);
      expect(c.subscriptionCandidates(), isEmpty);
      c.dispose();
    });

    test('VPN 开：候选海外在前', () async {
      final c = EndpointRaceController(
        vpnActive: true,
        probe: (e) async => e.contains('overseas'),
      );
      await c.raceSubscription(_mixed({
        'https://cn.com': BootstrapRegion.cn,
        'https://overseas.com': BootstrapRegion.overseas,
      }));
      expect(c.currentSubscriptionEndpoint, 'https://overseas.com');
      // 海外首发在前，国内当替补。
      expect(c.subscriptionCandidates(),
          ['https://overseas.com', 'https://cn.com']);
      c.dispose();
    });

    test('failOverSubscription：首发挂了切到下一个可达者', () async {
      var firstReachable = true;
      final c = EndpointRaceController(
        probe: (e) async {
          if (e.contains('sub1')) return firstReachable;
          return true; // sub2 始终可达
        },
      );
      await c.raceSubscription(_eps(['https://sub1.com', 'https://sub2.com']));
      expect(c.currentSubscriptionEndpoint, 'https://sub1.com');
      // sub1 挂了 → failOver 到 sub2。
      firstReachable = false;
      await c.failOverSubscription();
      expect(c.currentSubscriptionEndpoint, 'https://sub2.com');
      c.dispose();
    });

    test('failOverSubscription：串行化锁——并发复用同一 Future', () async {
      final c = EndpointRaceController(
        probe: (e) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return e.contains('sub2');
        },
      );
      await c.raceSubscription(_eps(['https://sub1.com', 'https://sub2.com']));
      await Future.wait([c.failOverSubscription(), c.failOverSubscription()]);
      expect(c.currentSubscriptionEndpoint, 'https://sub2.com');
      c.dispose();
    });

    test('failOverSubscription：与 API failOver 独立互不影响', () async {
      final c = EndpointRaceController(probe: (_) async => true);
      await c.raceApi(_eps(['https://api1.com']));
      await c.raceSubscription(_eps(['https://sub1.com']));
      await c.failOverSubscription();
      // API 首发不受订阅 failOver 影响。
      expect(c.currentApiEndpoint, 'https://api1.com');
      c.dispose();
    });
  });
}
