/// Bootstrap 解密后内层 payload（R15 / D58 / v0.2 R4.9 地区感知 + R4.7 自举）。
///
/// **v2 格式（R4.9/R4.7，2026-06-02）**：endpoint 由纯字符串升级为 `{url, region}` 对象，
/// 新增 `next_bootstrap_urls`（地址自举）。app 未发布零真实用户 → 破坏性升级，不留 v1 字段。
///
/// v0.1 只消费 `api_endpoints` + `subscription_endpoints`；`commands`/`announcements`/
/// `client_update` 等未知字段视而不见（R15.A.2 forward-compatible，fromJson 只取已知字段）。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part '../generated/models/bootstrap_payload.freezed.dart';
part '../generated/models/bootstrap_payload.g.dart';

/// endpoint 地区（R4.9 地区感知竞速；运营手标，客户端不猜 IP）。
///
/// - `overseas`：海外地址（VPN 开启时优先 —— 流量已出国，连海外顺路 + 无 GFW + CDN 体验好）
/// - `cn`：中国大陆地址（VPN 未开时裸网络直连快；VPN 开时作兜底）
/// - `unknown`：缺标签 / 非法取值的兜底档（健壮性，不崩）
enum BootstrapRegion { overseas, cn, unknown }

/// 字符串 → BootstrapRegion（大小写不敏感；未知值归 unknown）。
BootstrapRegion _regionFromString(String? raw) => switch (raw?.toLowerCase()) {
      'overseas' => BootstrapRegion.overseas,
      'cn' => BootstrapRegion.cn,
      _ => BootstrapRegion.unknown,
    };

String _regionToString(BootstrapRegion r) => r.name;

/// 单个 endpoint（地址 + 地区标签，R4.9）。
@freezed
abstract class BootstrapEndpoint with _$BootstrapEndpoint {
  const factory BootstrapEndpoint({
    required String url,
    @JsonKey(fromJson: _regionFromString, toJson: _regionToString)
    @Default(BootstrapRegion.unknown)
    BootstrapRegion region,
  }) = _BootstrapEndpoint;

  const BootstrapEndpoint._();

  /// 容错 fromJson：支持两种输入形态（破坏性升级后正式是对象，字符串仅作健壮性兜底）：
  /// - 对象 `{url, region}` → 正常解析（v2 正式格式）
  /// - 纯字符串 `"https://..."` → `{url:字符串, region:unknown}`（误填兜底，不崩）
  factory BootstrapEndpoint.fromDynamic(dynamic raw) {
    if (raw is String) {
      return BootstrapEndpoint(url: raw, region: BootstrapRegion.unknown);
    }
    if (raw is Map<String, dynamic>) {
      return BootstrapEndpoint.fromJson(raw);
    }
    return const BootstrapEndpoint(url: '', region: BootstrapRegion.unknown);
  }

  factory BootstrapEndpoint.fromJson(Map<String, dynamic> json) =>
      _$BootstrapEndpointFromJson(json);

  /// url 规范化后的副本（trim + 去末尾斜杠，保留 scheme + 路径前缀）。
  BootstrapEndpoint normalized() =>
      copyWith(url: BootstrapPayload.normalizeEndpoint(url));
}

@freezed
abstract class BootstrapPayload with _$BootstrapPayload {
  const factory BootstrapPayload({
    @JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson)
    @Default(<BootstrapEndpoint>[])
    List<BootstrapEndpoint> apiEndpoints,
    @JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson)
    @Default(<BootstrapEndpoint>[])
    List<BootstrapEndpoint> subscriptionEndpoints,
    // R4.7 地址自举：下一代 bootstrap 分发地址（客户端拉取后缓存滚动）。
    @JsonKey(name: 'next_bootstrap_urls')
    @Default(<String>[])
    List<String> nextBootstrapUrls,
  }) = _BootstrapPayload;

  const BootstrapPayload._();

  factory BootstrapPayload.fromJson(Map<String, dynamic> json) =>
      _$BootstrapPayloadFromJson(json);

  /// 有效性（R15.B.7：两个 endpoint 列表各 ≥1 个非空 url）。
  bool get isValid =>
      apiEndpoints.any((e) => e.url.isNotEmpty) &&
      subscriptionEndpoints.any((e) => e.url.isNotEmpty);

  /// api endpoint 的纯 url 列表（下游竞速/SDK 需要 baseUrl 字符串时用）。
  List<String> get apiUrls =>
      apiEndpoints.map((e) => e.url).where((u) => u.isNotEmpty).toList();

  /// subscription endpoint 的纯 url 列表。
  List<String> get subscriptionUrls => subscriptionEndpoints
      .map((e) => e.url)
      .where((u) => u.isNotEmpty)
      .toList();

  /// 返回 endpoint 规范化后的副本（解密成功后统一调，下游拿到干净 url）。
  ///
  /// 规范化（[normalizeEndpoint]）：trim + 去末尾 `/`（避免 `/omo/` + `/api/v1` 双斜杠），
  /// 保留 scheme `://` 与路径前缀（`/omo`）；丢弃 url 为空的 endpoint；nextBootstrapUrls 同样 trim。
  BootstrapPayload normalized() => BootstrapPayload(
        apiEndpoints: _normalizeEndpoints(apiEndpoints),
        subscriptionEndpoints: _normalizeEndpoints(subscriptionEndpoints),
        nextBootstrapUrls: nextBootstrapUrls
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false),
      );

  static List<BootstrapEndpoint> _normalizeEndpoints(
          List<BootstrapEndpoint> eps) =>
      eps
          .map((e) => e.normalized())
          .where((e) => e.url.isNotEmpty)
          .toList(growable: false);

  /// 单个 endpoint url 规范化：trim + 去末尾斜杠（保留 `scheme://`）。
  ///
  /// 例：`https://h/omo/ ` → `https://h/omo`；`https://h/` → `https://h`；`https://` 原样。
  static String normalizeEndpoint(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final schemeIdx = s.indexOf('://');
    final base = schemeIdx >= 0 ? schemeIdx + 3 : 0;
    var end = s.length;
    while (end > base && s.codeUnitAt(end - 1) == 0x2F /* '/' */) {
      end--;
    }
    return s.substring(0, end);
  }
}

/// JSON 数组 → endpoint 列表（容错每个元素：对象 / 字符串）。
List<BootstrapEndpoint> _endpointsFromJson(dynamic raw) {
  if (raw is! List) return const [];
  return raw.map(BootstrapEndpoint.fromDynamic).toList();
}
