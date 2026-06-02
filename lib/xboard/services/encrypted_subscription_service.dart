/// R4.1 加密订阅拉取 + 解密（客户端实现，方案 A「SDK 文件化订阅」的拉取/解密环节）。
///
/// **职责**：构造加密订阅 URL（方案 b）→ 拉密文 → 复用 bootstrap 的多档宽容解析抽 envelope →
/// 复用 [BootstrapDecryptor] 的 AES-GCM 核心解密（AAD `xboard-encrypted-sub-v1`）→ 返明文
/// ClashMeta YAML 字节。**不写文件、不碰 FlClash**（那是 [ProfileSyncPort.putFileProfile] 的
/// 职责，由 R4.6 sync 编排串起）。
///
/// **为什么放客户端 `lib/xboard/` 而非 SDK**（2026-06-03 方案 B 定稿）：近 100% 复用现成
/// bootstrap 基建——[BootstrapDecryptor] 的 AES-GCM 核心（只换 AAD 参数）、[buildReleasedIsolatedDio]
/// 的放行 dio（裸 IP 证书放行）、[BootstrapFetcher.parseEnvelopeBytes] 的多档兼容解析；与 bootstrap
/// 同构、零 SDK 改动零 θ-4、failOver 天然接 R4.9 的 [EndpointRaceController]。SDK 唯一贡献是
/// `getSubscribeUrl()`（带 token 的原订阅 URL），经反腐层 [XboardService] 注入。
///
/// **URL 构造（方案 b，contract 0-B）**：原订阅 URL `https://host/{path}/{token}` → 在
/// `/{token}` 前插 `/encrypted/` → `https://host/{path}/encrypted/{token}`（无需知 subscribe_path）；
/// host 可换成 R4.9 竞速选中的订阅 endpoint（path+token 保留，同 v0.1 refreshUrl 逻辑）。
///
/// **错误分流（contract §5）**：HTTP 非 2xx → 后端明文 JSON `{code,message}`（不加密），按
/// code 归类（token 类 / 无套餐 / 加密未配置 / 其他）；2xx → 走解密；解密失败 → 数据损坏。
///
/// **R4.2 failOver**（[fetchWithFailOver]）：按候选 host 列表（竞速排序 + 去重，来自
/// `EndpointRaceController.subscriptionCandidates()`）串行试穿——某 host 网络/解密失败就试下一个，
/// 业务类错误（token/无套餐/未配置）立即停（换 host 无意义），全程受总预算约束；候选为空退回原
/// URL host 兜底。"列表是输入、竞速是优化"——不依赖竞速是否跑完，无空窗。
///
/// **永不抛**（Property 1）：任何失败返 [EncryptedSubscriptionResult.failure]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../config/bootstrap_constants.dart';
import 'bootstrap_decryptor.dart';
import 'bootstrap_fetcher.dart' show BootstrapFetcher;
import 'xboard_release_dio.dart';

/// 加密订阅拉取失败原因（UI 文案分流 + 上层 sync 归一）。
enum EncryptedSubscriptionFailure {
  /// 订阅 URL 缺失 / 非法（getSubscribeUrl 失败或 URL 无 token 段）。
  noSubscribeUrl,

  /// 鉴权失败（token 无效 / 过期 / 被封，后端 40302/40303/40304）。
  unauthorized,

  /// 无有效套餐（后端 40305）。
  noActivePlan,

  /// 后端加密未配置（50001）/ 插件禁用（404）—— 运营侧问题，非客户端可恢复。
  serverNotConfigured,

  /// 网络失败（连不上 / 超时 / 全 endpoint 不可达）。
  network,

  /// 拉到响应但解密 / 校验失败（密钥不符 / tag 不符 / 数据损坏 / 非合法 envelope）。
  decryptFailed,

  /// 其他未预期错误（HTTP 其他码 / 解析异常）。
  unknown,
}

/// 加密订阅拉取结果（成功携明文 YAML 字节 + 命中 endpoint；失败携原因 + 后端 message）。
class EncryptedSubscriptionResult {
  const EncryptedSubscriptionResult._({
    this.yamlBytes,
    this.winnerUrl,
    this.failure,
    this.serverMessage,
  });

  factory EncryptedSubscriptionResult.success({
    required Uint8List yamlBytes,
    required String winnerUrl,
  }) =>
      EncryptedSubscriptionResult._(yamlBytes: yamlBytes, winnerUrl: winnerUrl);

  factory EncryptedSubscriptionResult.failure(
    EncryptedSubscriptionFailure failure, {
    String? serverMessage,
  }) =>
      EncryptedSubscriptionResult._(
          failure: failure, serverMessage: serverMessage);

  /// 成功时的明文 ClashMeta YAML 字节（喂 [ProfileSyncPort.putFileProfile]）。
  final Uint8List? yamlBytes;

  /// 命中的加密订阅 URL（成功时，供日志 / 调试）。
  final String? winnerUrl;

  /// 失败原因。
  final EncryptedSubscriptionFailure? failure;

  /// 后端透传的错误 message（错误文案透传机制，UI 可直接展示）。
  final String? serverMessage;

  bool get isSuccess => yamlBytes != null;
}

/// 加密订阅拉取服务（注入解密器 + dio 便于测试）。
class EncryptedSubscriptionService {
  EncryptedSubscriptionService({
    required BootstrapDecryptor decryptor,
    String aad = kEncryptedSubscriptionAad,
    Dio? dio,
  })  : _decryptor = decryptor,
        _aad = aad,
        _dio = dio ?? buildReleasedIsolatedDio(timeout: kEncryptedSubscriptionTimeout);

  final BootstrapDecryptor _decryptor;
  final String _aad;
  final Dio _dio;

  /// 把原订阅 URL 改写为加密订阅 URL（方案 b）：在最后一段（token）前插 `/encrypted/`。
  ///
  /// `https://h/thunder/b012ef` → `https://h/thunder/encrypted/b012ef`。
  /// 保留 scheme / host / 中间 path 段 / query。无法解析或无路径段 → 返 null（调用方降级）。
  ///
  /// [overrideHost]（可选，R4.9 竞速选中的订阅 endpoint）：形如 `https://1.2.3.4` 或
  /// `https://sub.cdn.com`，替换原 URL 的 scheme+host（保留改写后的 path+token+query）。
  @visibleForTesting
  static String? buildEncryptedUrl(String originalSubscribeUrl,
      {String? overrideHost}) {
    final uri = Uri.tryParse(originalSubscribeUrl.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null; // 无 token 段，无法构造。

    // 在最后一段（token）前插 'encrypted'。
    final token = segments.removeLast();
    final newSegments = [...segments, kEncryptedSubscriptionPathSegment, token];

    var result = uri.replace(pathSegments: newSegments);

    if (overrideHost != null && overrideHost.trim().isNotEmpty) {
      final hostUri = Uri.tryParse(overrideHost.trim());
      if (hostUri != null && hostUri.host.isNotEmpty) {
        result = result.replace(
          scheme: hostUri.scheme.isEmpty ? result.scheme : hostUri.scheme,
          host: hostUri.host,
          port: hostUri.hasPort ? hostUri.port : null,
        );
      }
    }
    return result.toString();
  }

  /// 拉取 + 解密加密订阅，返明文 ClashMeta YAML 字节。永不抛。
  ///
  /// [originalSubscribeUrl]：SDK `getSubscribeUrl()` 返回的原订阅 URL（含 token）。
  /// [subscriptionEndpoint]（可选，R4.9）：竞速选中的订阅 endpoint host，替换原 URL host。
  Future<EncryptedSubscriptionResult> fetch(
    String originalSubscribeUrl, {
    String? subscriptionEndpoint,
  }) async {
    final url = buildEncryptedUrl(originalSubscribeUrl,
        overrideHost: subscriptionEndpoint);
    if (url == null) {
      return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.noSubscribeUrl);
    }
    return _fetchOne(url);
  }

  /// R4.2：按候选 host 列表串行 failOver 拉取（首发挂了顺位试下一个，总预算内）。
  ///
  /// - [originalSubscribeUrl]：SDK 原订阅 URL（提供 token + path，host 会被候选替换）。
  /// - [candidateHosts]：已排序去重的订阅 endpoint host 串（来自
  ///   `EndpointRaceController.subscriptionCandidates()`，首发在前 / VPN 开海外在前）。
  ///   **空列表** → 退回用原始 URL host 原样拉一次（终极兜底，列表未解出时不致无路可走）。
  /// - [budget]：总预算（默认 [kEncryptedSubscriptionTotalBudget]），耗尽即停止试更多 host。
  ///
  /// **智能停止**（不是所有失败都值得换 host）：
  /// - `network` / `decryptFailed`（连不上 / 超时 / 数据损坏）→ 该 host 不行，**试下一个**。
  /// - `unauthorized` / `noActivePlan` / `serverNotConfigured`（后端明确拒绝）→ 换 host 也一样，
  ///   **立即返回**该业务错误（呼应错误文案透传，不浪费时间穷举）。
  ///
  /// 返回首个成功结果；全部失败返回**最后一次有意义的失败**（优先保留业务错误，否则网络错误）。
  Future<EncryptedSubscriptionResult> fetchWithFailOver(
    String originalSubscribeUrl, {
    required List<String> candidateHosts,
    Duration budget = kEncryptedSubscriptionTotalBudget,
  }) async {
    // 候选为空 → 原始 URL host 兜底（不替换 host）。
    if (candidateHosts.isEmpty) {
      return fetch(originalSubscribeUrl);
    }

    final deadline = DateTime.now().add(budget);
    EncryptedSubscriptionResult? lastFailure;

    for (final host in candidateHosts) {
      if (DateTime.now().isAfter(deadline)) break; // 总预算耗尽。
      final r = await fetch(originalSubscribeUrl, subscriptionEndpoint: host);
      if (r.isSuccess) return r;

      // 业务类错误：换 host 无意义，立即返回。
      if (_isTerminal(r.failure!)) return r;

      // 网络 / 解密类：记录后试下一个 host。
      lastFailure = r;
    }
    // 全部失败 → 返最后一次失败（候选非空时 lastFailure 必非 null）。
    return lastFailure ??
        EncryptedSubscriptionResult.failure(
            EncryptedSubscriptionFailure.network);
  }

  /// 该失败是否「终态」（换 host 也救不了，应立即停止 failOver）。
  static bool _isTerminal(EncryptedSubscriptionFailure f) => switch (f) {
        EncryptedSubscriptionFailure.unauthorized ||
        EncryptedSubscriptionFailure.noActivePlan ||
        EncryptedSubscriptionFailure.serverNotConfigured ||
        EncryptedSubscriptionFailure.noSubscribeUrl =>
          true,
        EncryptedSubscriptionFailure.network ||
        EncryptedSubscriptionFailure.decryptFailed ||
        EncryptedSubscriptionFailure.unknown =>
          false,
      };

  /// 单个加密订阅 URL 的拉取 + 解密（[fetch] / [fetchWithFailOver] 共用核心）。永不抛。
  Future<EncryptedSubscriptionResult> _fetchOne(String url) async {
    // 1. 拉密文（放行 dio，bytes 响应）。
    Response<List<int>> resp;
    try {
      resp = await _dio.getUri<List<int>>(
        Uri.parse(url),
        options: Options(responseType: ResponseType.bytes),
      );
    } on DioException catch (e) {
      // 4xx/5xx 也走这里（dio 默认 validateStatus 仅 2xx 不抛 → 实际非 2xx 抛 badResponse）。
      final r = e.response;
      if (r != null && r.statusCode != null) {
        return _mapHttpError(r.statusCode!, _bytesToString(r.data));
      }
      return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.network);
    } catch (_) {
      return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.network);
    }

    final code = resp.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      return _mapHttpError(code, _bytesToString(resp.data));
    }

    final data = resp.data;
    if (data == null || data.isEmpty) {
      return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.decryptFailed);
    }
    final bytes = Uint8List.fromList(data);

    // 2. 多档宽容抽 envelope（复用 bootstrap 解析：JSON 信封 / 裸 base64 / HTML 包裹等）。
    final parsed = BootstrapFetcher.parseEnvelopeBytes(bytes);
    if (parsed == null) {
      return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.decryptFailed);
    }

    // 3. AES-GCM 核心解密（AAD = 加密订阅用途）。
    final raw = await _decryptor.decryptCiphertext(
      base64Cipher: parsed.envelope.encrypted,
      aad: _aad,
    );
    if (!raw.isSuccess || raw.clearBytes == null) {
      return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.decryptFailed);
    }

    return EncryptedSubscriptionResult.success(
      yamlBytes: raw.clearBytes!,
      winnerUrl: url,
    );
  }

  /// HTTP 非 2xx → 后端明文 JSON `{code,message}` 分流（contract §5 / 插件 DESIGN.md 错误码）。
  EncryptedSubscriptionResult _mapHttpError(int httpStatus, String? body) {
    final parsed = _parseErrorBody(body);
    final code = parsed.$1;
    final message = parsed.$2;

    // 插件错误码（DESIGN.md）：40301 token 必填 / 40302 invalid / 40303 banned /
    // 40304 expired / 40305 no active plan / 50001 encryption not configured / 404 禁用。
    final failure = switch (code) {
      40301 || 40302 || 40303 || 40304 => EncryptedSubscriptionFailure.unauthorized,
      40305 => EncryptedSubscriptionFailure.noActivePlan,
      50001 => EncryptedSubscriptionFailure.serverNotConfigured,
      _ => switch (httpStatus) {
          401 || 403 => EncryptedSubscriptionFailure.unauthorized,
          404 => EncryptedSubscriptionFailure.serverNotConfigured,
          >= 500 => EncryptedSubscriptionFailure.network,
          _ => EncryptedSubscriptionFailure.unknown,
        },
    };
    return EncryptedSubscriptionResult.failure(failure, serverMessage: message);
  }

  /// 解析后端错误体 → (code?, message?)。容错：非 JSON / 缺字段返 (null, 原文/null)。
  (int?, String?) _parseErrorBody(String? body) {
    if (body == null || body.trim().isEmpty) return (null, null);
    try {
      final decoded = jsonDecode(body.trim());
      if (decoded is Map) {
        final rawCode = decoded['code'];
        final code = rawCode is int
            ? rawCode
            : (rawCode is num ? rawCode.toInt() : int.tryParse('$rawCode'));
        final msg = decoded['message']?.toString();
        return (code, msg);
      }
    } catch (_) {
      // 非 JSON 错误体（如 CDN HTML）→ 当纯文本 message。
    }
    return (null, body.trim());
  }

  String? _bytesToString(List<int>? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
