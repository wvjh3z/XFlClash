/// 自建隔离放行 dio 工厂（R15 bootstrap 拉取 + R4.1 加密订阅拉取共享）。
///
/// **为什么自建**（D60 / F76）：启动早期 `globalState.attach` 未完成，FlClash
/// `HttpOverrides.findProxy` 访问未就绪运行时 ClashConfig 会抛 LateInitializationError；
/// 自建 adapter 覆盖 `findProxy=DIRECT` 绕过。
///
/// **⚠️ 证书校验全放行**（用户 2026-06-01 知情决策）：与 FlClash 上游 HttpOverrides `=> true`
/// 一致全放行（裸 IP 如 `https://223.26.52.196` 证书校验失败由此解决）。接受明网 MITM 风险
/// （见 SECURITY.md「Bootstrap TLS 全放行」+ design 决策 #12 修订）。R4.1 加密订阅拉取沿用同款
/// 放行 dio——加密订阅密文经 AES-GCM tag 校验防篡改，即便 MITM 也无法注入伪造配置（解密失败丢弃）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 构造自建隔离放行 dio：直连（findProxy=DIRECT）+ 证书全放行 + bytes 响应。
///
/// [timeout] 连接 / 接收超时（bootstrap 用 5s，加密订阅密文较大用 15s）。
Dio buildReleasedIsolatedDio({required Duration timeout}) {
  final dio = Dio(BaseOptions(
    connectTimeout: timeout,
    receiveTimeout: timeout,
    // bytes 拿原始字节，不让 dio 按 Content-Type 自动 parse；自行解 BOM/UTF-8/JSON。
    responseType: ResponseType.bytes,
    followRedirects: true,
    maxRedirects: 5,
  ));
  dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    // ⚠️ 证书全放行（用户知情决策，见库注释）。
    client.badCertificateCallback = (cert, host, port) => true;
    client.findProxy = (uri) => 'DIRECT'; // 直连，不走 FlClash 代理。
    return client;
  });
  return dio;
}
