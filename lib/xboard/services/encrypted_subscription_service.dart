/// R4.1 加密订阅拉取 + 解密（客户端实现，方案 A「SDK 文件化订阅」的拉取/解密环节）。
///
/// **职责**：构造加密订阅 URL（方案 b）→ 拉密文 → 复用 bootstrap 的多档宽容解析抽 envelope →
/// 复用 [BootstrapDecryptor] 的 AES-GCM 核心解密（AAD `xboard-encrypted-sub-v1`）→ 返明文
/// ClashMeta YAML 字节。**不写文件、不碰 FlClash**（那是 [ProfileSyncPort.putFileProfile] 的
/// 职责，由 R4.6 sync 编排串起）。
///
/// **为什么放客户端 `lib/xboard/` 而非 SDK**（2026-06-03 方案 B 定稿）：近 100% 复用现成
/// bootstrap 基建——[BootstrapDecryptor] 的 AES-GCM 核心（只换 AAD 参数）、[buildReleasedIsolatedDio]
/// 的独立 dio（裸 IP 证书放行，代理继承全局）、[BootstrapFetcher.parseEnvelopeBytes] 的多档兼容解析；
/// 与 bootstrap 同构、零 SDK 改动零 θ-4、failOver 天然接 R4.9 的 [EndpointRaceController]。SDK 唯一贡献是
/// `getSubscribeUrl()`（带 token 的原订阅 URL），经反腐层 [XboardService] 注入。
///
/// **URL 构造（方案 b，contract 0-B）**：原订阅 URL `https://host/{path}/{token}` → 在
/// `/{token}` 前插 `/encrypted/` → `https://host/{path}/encrypted/{token}`（无需知 subscribe_path）；
/// host 可换成 R4.9 竞速选中的订阅 endpoint（path+token 保留，同 v0.1 refreshUrl 逻辑）。
///
/// **错误分流（contract §5）**：HTTP 非 2xx → 后端明文 JSON `{code,message}`（不加密），按
/// code 归类（token 类 / 无套餐 / 加密未配置 / 其他）；2xx → 走解密；解密失败 → 数据损坏。
///
/// 实际下载按地区分组、组内最多两个并发；首个解密且基本 YAML 合法的结果胜出。
/// 公开 guest 探测只提供排序提示，不替代真实下载。副作用由同步服务执行一次。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting, debugPrint;
import 'package:yaml/yaml.dart';

import '../models/bootstrap_payload.dart';

import '../config/bootstrap_constants.dart';
import 'bootstrap_decryptor.dart';
import 'bootstrap_fetcher.dart' show BootstrapFetcher;
import 'xboard_release_dio.dart';
import 'bounded_response_reader.dart';

/// 加密订阅拉取失败原因（UI 文案分流 + 上层 sync 归一）。
enum EncryptedSubscriptionFailure {
  /// 订阅 URL 缺失 / 非法（getSubscribeUrl 失败或 URL 无 token 段）。
  noSubscribeUrl,

  /// 鉴权失败（token 无效 / 被封，后端 40301/40302/40303）。
  unauthorized,

  /// 套餐已过期（后端 40304）。token 有效但订阅过期 → UI 引导续费/购买，**不是登录过期**。
  subscriptionExpired,

  /// 无有效套餐（后端 40305）。
  noActivePlan,

  /// 本周期流量已耗尽（后端 40307，v1.1.0 起）。token/套餐有效但流量用尽 → UI 引导购买流量包/套餐。
  trafficExhausted,

  /// 后端明确返回加密未配置（50001）；裸 404 不能据此定性。
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
  }) => EncryptedSubscriptionResult._(
    failure: failure,
    serverMessage: serverMessage,
  );

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
    this.maxResponseBytes = kEncryptedSubscriptionMaxResponseBytes,
  }) : _decryptor = decryptor,
       _aad = aad,
       _dio =
           dio ??
           buildReleasedIsolatedDio(timeout: kEncryptedSubscriptionTimeout);

  final BootstrapDecryptor _decryptor;
  final String _aad;
  final Dio _dio;
  final int maxResponseBytes;

  /// 把原订阅 URL 改写为加密订阅 URL（方案 b）：在最后一段（token）前插 `/encrypted/`。
  ///
  /// `https://h/thunder/b012ef` → `https://h/thunder/encrypted/b012ef`。
  /// 保留 scheme / host / 中间 path 段 / query。无法解析或无路径段 → 返 null（调用方降级）。
  ///
  /// [overrideHost]（可选，R4.9 竞速选中的订阅 endpoint）：形如 `https://1.2.3.4` 或
  /// `https://sub.cdn.com`，替换原 URL 的 scheme+host（保留改写后的 path+token+query）。
  @visibleForTesting
  static String? buildEncryptedUrl(
    String originalSubscribeUrl, {
    String? overrideHost,
  }) {
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
    final url = buildEncryptedUrl(
      originalSubscribeUrl,
      overrideHost: subscriptionEndpoint,
    );
    if (url == null) {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.noSubscribeUrl,
      );
    }
    return _fetchOne(url);
  }

  /// 总预算只包含下载/解密阶段。VPN 开时海外先行，预留一半预算给其他地区。
  /// 同组每个请求最多占用 5 秒，防止前两个慢地址独占全部预算。
  Future<EncryptedSubscriptionResult> fetchWithFailOver(
    String originalSubscribeUrl, {
    required List<String> candidateHosts,
    List<BootstrapEndpoint>? endpoints,
    bool vpnActive = false,
    CancelToken? cancelToken,
    Duration budget = kEncryptedSubscriptionTotalBudget,
    Duration attemptTimeout = const Duration(seconds: 5),
  }) async {
    final seen = <String>{};
    final candidates =
        (endpoints ?? candidateHosts.map((url) => BootstrapEndpoint(url: url)))
            .where((e) => e.url.isNotEmpty && seen.add(e.url))
            .toList();
    final overseas = candidates
        .where((e) => e.region == BootstrapRegion.overseas)
        .toList();
    final rest = candidates
        .where((e) => e.region != BootstrapRegion.overseas)
        .toList();
    final groups = vpnActive && overseas.isNotEmpty && rest.isNotEmpty
        ? [overseas, rest]
        : [candidates];
    final clock = Stopwatch()..start();
    final failures = <EncryptedSubscriptionResult>[];
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      if (cancelToken?.isCancelled ?? false) break;
      final remaining = budget - clock.elapsed;
      if (remaining <= Duration.zero) break;
      final groupBudget = groups.length == 2 && groupIndex == 0
          ? Duration(microseconds: remaining.inMicroseconds ~/ 2)
          : remaining;
      final hosts = groups[groupIndex];
      final done = Completer<EncryptedSubscriptionResult?>();
      final tokens = <CancelToken>[];
      var next = 0;
      var workers = 0;
      // Empty configuration retains the original URL, under the same deadline.
      final count = hosts.isEmpty ? 1 : hosts.length;
      final timer = Timer(groupBudget, () {
        if (!done.isCompleted) done.complete(null);
      });
      if (cancelToken != null) {
        unawaited(
          cancelToken.whenCancel.then((_) {
            if (!done.isCompleted) done.complete(null);
          }),
        );
      }
      Future<void> worker() async {
        workers++;
        try {
          while (!done.isCompleted && next < count) {
            final index = next++;
            final endpoint = hosts.isEmpty ? null : hosts[index];
            final token = CancelToken();
            tokens.add(token);
            final watch = Stopwatch()..start();
            final url = buildEncryptedUrl(
              originalSubscribeUrl,
              overrideHost: endpoint?.url,
            );
            final result = url == null
                ? EncryptedSubscriptionResult.failure(
                    EncryptedSubscriptionFailure.noSubscribeUrl,
                  )
                : await _fetchOne(url, cancelToken: token).timeout(
                    attemptTimeout,
                    onTimeout: () {
                      token.cancel('attempt deadline');
                      return EncryptedSubscriptionResult.failure(
                        EncryptedSubscriptionFailure.network,
                      );
                    },
                  );
            if (done.isCompleted) return;
            debugPrint(
              '[Subscription] download group=$groupIndex candidate=$index '
              'region=${endpoint?.region.name ?? "original"} ms=${watch.elapsedMilliseconds} '
              'result=${result.isSuccess ? "ok" : result.failure?.name}',
            );
            if (result.isSuccess) {
              done.complete(result);
              return;
            }
            failures.add(result);
          }
        } finally {
          workers--;
          if (workers == 0 && !done.isCompleted) done.complete(null);
        }
      }

      unawaited(worker());
      if (count > 1) unawaited(worker());
      final winner = await done.future;
      timer.cancel();
      for (final token in tokens) {
        if (!token.isCancelled) token.cancel('race finished');
      }
      if (winner != null) return winner;
    }
    // A single mirror's rejection must not suppress a valid response from another.
    // Stable enum priority makes the all-failed result independent of response timing.
    failures.sort((a, b) => a.failure!.index.compareTo(b.failure!.index));
    return failures.where((r) => _isBusinessFailure(r.failure!)).firstOrNull ??
        failures.firstOrNull ??
        EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.network,
        );
  }

  /// 全部候选失败时优先保留明确业务结果，不用于提前终止竞速。
  static bool _isBusinessFailure(EncryptedSubscriptionFailure f) => switch (f) {
    EncryptedSubscriptionFailure.unauthorized ||
    EncryptedSubscriptionFailure.subscriptionExpired ||
    EncryptedSubscriptionFailure.noActivePlan ||
    EncryptedSubscriptionFailure.trafficExhausted ||
    EncryptedSubscriptionFailure.serverNotConfigured ||
    EncryptedSubscriptionFailure.noSubscribeUrl => true,
    EncryptedSubscriptionFailure.network ||
    EncryptedSubscriptionFailure.decryptFailed ||
    EncryptedSubscriptionFailure.unknown => false,
  };

  /// 单个加密订阅 URL 的拉取 + 解密（[fetch] / [fetchWithFailOver] 共用核心）。永不抛。
  Future<EncryptedSubscriptionResult> _fetchOne(
    String url, {
    CancelToken? cancelToken,
  }) async {
    // 1. Stream decoded response bytes with a per-candidate size limit.
    Response<Uint8List> resp;
    try {
      resp = await readBoundedResponse(
        _dio,
        Uri.parse(url),
        maxBytes: maxResponseBytes,
        cancelToken: cancelToken,
      );
    } on ResponseTooLargeException {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.decryptFailed,
      );
    } on DioException catch (e) {
      // 4xx/5xx 也走这里（dio 默认 validateStatus 仅 2xx 不抛 → 实际非 2xx 抛 badResponse）。
      final r = e.response;
      if (r != null && r.statusCode != null) {
        return _mapHttpError(r.statusCode!, _bytesToString(r.data));
      }
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.network,
      );
    } catch (_) {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.network,
      );
    }

    final code = resp.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      return _mapHttpError(code, _bytesToString(resp.data));
    }

    final data = resp.data;
    if (data == null || data.isEmpty) {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.decryptFailed,
      );
    }
    final bytes = data;

    // 2. 多档宽容抽 envelope（复用 bootstrap 解析：JSON 信封 / 裸 base64 / HTML 包裹等）。
    final parsed = BootstrapFetcher.parseEnvelopeBytes(bytes);
    if (parsed == null) {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.decryptFailed,
      );
    }

    // 3. AES-GCM 核心解密（AAD = 加密订阅用途）。
    final raw = await _decryptor.decryptCiphertext(
      base64Cipher: parsed.envelope.encrypted,
      aad: _aad,
    );
    if (!raw.isSuccess || raw.clearBytes == null) {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.decryptFailed,
      );
    }

    // Basic syntax/shape only; full core validation stays in the existing Profile port.
    try {
      final yaml = loadYaml(utf8.decode(raw.clearBytes!));
      if (yaml is! YamlMap ||
          !(yaml['proxies'] is YamlList ||
              yaml['proxy-providers'] is YamlMap)) {
        return EncryptedSubscriptionResult.failure(
          EncryptedSubscriptionFailure.decryptFailed,
        );
      }
    } catch (_) {
      return EncryptedSubscriptionResult.failure(
        EncryptedSubscriptionFailure.decryptFailed,
      );
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
    // 40304 subscription expired / 40305 no active plan / 40307 traffic exhausted（v1.1.0）/
    // 50001 encryption not configured / 404 禁用。
    final failure = switch (code) {
      40301 || 40302 || 40303 => EncryptedSubscriptionFailure.unauthorized,
      40304 => EncryptedSubscriptionFailure.subscriptionExpired,
      40305 => EncryptedSubscriptionFailure.noActivePlan,
      40307 => EncryptedSubscriptionFailure.trafficExhausted,
      50001 => EncryptedSubscriptionFailure.serverNotConfigured,
      _ => switch (httpStatus) {
        401 || 403 => EncryptedSubscriptionFailure.network,
        404 => EncryptedSubscriptionFailure.network,
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
