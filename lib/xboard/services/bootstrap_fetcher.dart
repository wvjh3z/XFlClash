/// Bootstrap 远端拉取（R15.H.40 / D60 / θ-1）—— 异步阶段（runApp 后 fire-and-forget）。
///
/// **自建独立 dio + IOHttpClientAdapter**（D60 / F76）：启动早期 globalState.attach 未完成，
/// FlClashHttpOverrides.findProxy 访问未就绪运行时 ClashConfig 会抛 LateInitializationError。
/// 自建 adapter 覆盖 findProxy=DIRECT 绕过。
///
/// **🔴 θ-1 安全约束**：`client.badCertificateCallback = null`——FlClash 全局 HttpOverrides 设
/// `=> true` 全境放行任意证书（MITM 风险），自建 client 继承该行为，**必须显式 reset 为 null**
/// 恢复 dart:io 默认严格 TLS 校验（v0.1 不开 cert pinning，决策 #12，至少保严格 hostname 校验）。
///
/// **串行 + 30s 总预算**（R15.B.4/B.6）：串行尝试所有镜像（保留需求锁定的串行语义），单镜像 5s
/// 超时，总 30s 预算；全失败降级沿用本地 endpoint（不阻塞首屏）。永不抛（Property 1）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../config/bootstrap_constants.dart';
import '../models/bootstrap_envelope.dart';
import '../models/bootstrap_payload.dart';
import 'bootstrap_decryptor.dart';
import 'sentry_bootstrap.dart';

/// 远端拉取结果（成功携 payload + 命中镜像；失败为 null payload）。
class BootstrapFetchResult {
  const BootstrapFetchResult({
    this.payload,
    this.winnerUrl,
    this.winnerEnvelope,
    this.lastFailure,
  });

  final BootstrapPayload? payload;
  final String? winnerUrl;

  /// 命中镜像的外层 envelope（成功时供 [BootstrapLocalLoader.writeCache] 写缓存密文）。
  final BootstrapEnvelope? winnerEnvelope;

  /// 最后一次失败的解密分类（全失败时供 DD-23 tag）。
  final BootstrapDecryptFailure? lastFailure;

  bool get isSuccess => payload != null;
}

class BootstrapFetcher {
  BootstrapFetcher({
    required BootstrapDecryptor decryptor,
    Dio? dio,
  })  : _decryptor = decryptor,
        _dio = dio ?? _buildIsolatedDio();

  final BootstrapDecryptor _decryptor;
  final Dio _dio;

  /// 自建隔离 dio：直连 + 严格 TLS（θ-1）+ 5s 连接超时。
  static Dio _buildIsolatedDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: kBootstrapPerMirrorTimeout,
      receiveTimeout: kBootstrapPerMirrorTimeout,
      responseType: ResponseType.json,
    ));
    dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      final client = HttpClient();
      client.connectionTimeout = kBootstrapPerMirrorTimeout;
      // 🔴 θ-1：显式 reset，恢复 dart:io 默认严格 TLS 校验（绝不继承 FlClash `=> true`）。
      client.badCertificateCallback = null;
      client.findProxy = (uri) => 'DIRECT'; // 直连，不走 FlClash 代理。
      return client;
    });
    return dio;
  }

  /// 串行尝试所有 [mirrors]，30s 总预算；首个解出有效 payload 的镜像胜出。
  /// 全失败 → payload=null（调用方沿用本地 endpoint）。永不抛。
  Future<BootstrapFetchResult> fetchRemote(List<String> mirrors) async {
    final deadline = DateTime.now().add(kBootstrapTotalBudget);
    BootstrapDecryptFailure? lastFailure;

    for (final url in mirrors) {
      if (DateTime.now().isAfter(deadline)) break; // 30s 总预算耗尽。
      try {
        final resp = await _dio.getUri<Object?>(Uri.parse(url));
        if (resp.statusCode == null ||
            resp.statusCode! < 200 ||
            resp.statusCode! >= 300) {
          continue;
        }
        final data = resp.data;
        if (data is! Map) continue;
        final env = BootstrapEnvelope.fromJson(
            data.map((k, v) => MapEntry(k.toString(), v)));
        final result = await _decryptor.decryptAndValidate(env);
        if (result.isSuccess) {
          // DD-23：远端拉取成功 → envelope_source=remote（W5.7 / 5.7.2）。
          SentryBootstrap.tagBootstrap(
            stage: 'remote_fetched',
            envelopeSource: 'remote',
          );
          return BootstrapFetchResult(
            payload: result.payload,
            winnerUrl: url,
            winnerEnvelope: env,
          );
        }
        lastFailure = result.failure;
      } catch (_) {
        // 网络/解析失败 → 下一镜像（R15.B.4）。
        continue;
      }
    }
    // DD-23：全镜像失败 → 打 decryption_failure tag（5.7.3 五种路径各异）。
    if (lastFailure != null) {
      SentryBootstrap.tagBootstrap(decryptionFailure: lastFailure.tagValue);
    }
    return BootstrapFetchResult(lastFailure: lastFailure);
  }
}
