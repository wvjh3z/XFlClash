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
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show HttpConfig;

import '../config/xboard_user_agent.dart';

/// 「Xboard 管理流量统一放行策略」单一来源（SSoT，框架化）。
///
/// **What**：把"证书全放行 + UA 伪装 + 直连"这套策略集中到一处，供两条出站通道共用——
/// ① **SDK `HttpService` 通道**（登录/注册/账号/套餐/订单/支付/版本检查，经 [sdkHttpConfig]）；
/// ② **客户端 release dio 通道**（config.json / 加密订阅 / 软件更新下载，经 [buildReleasedIsolatedDio]）。
///
/// **Why（防两处漂移）**：历史上两条通道各写一份证书/UA 配置易不一致。集中到本类后，"全放行"的
/// 策略口径只有一处，改一处两条通道同步生效。
///
/// **⚠️ 安全（可用性优先决策）**：[allowBadCertificate] = true 放弃 TLS 中间人保护。用户明确以
/// 可用性优先（裸 IP endpoint 必需、accept MITM 风险，见 `SECURITY.md`）。能 AES-GCM 校验的内容
/// （config.json / 加密订阅）另有完整性保护；登录/账号等凭据流量在此前提下也一并接受全放行。
abstract final class XboardReleaseHttp {
  /// 浏览器 UA（按平台固定真实串，R4.4；与 release dio 同源）。
  static String get userAgent => XboardUserAgent.current;

  /// 证书全放行（可用性优先；裸 IP endpoint 无匹配证书时必需）。
  static const bool allowBadCertificate = true;

  /// 构造 SDK `HttpConfig`：**所有 SDK API 通道**（登录/注册/账号/套餐/订单/支付/版本检查）统一
  /// 用本配置，与 release dio 同策略（UA 伪装 + 证书全放行）。[timeoutSeconds] 连接/接收/发送统一超时。
  static HttpConfig sdkHttpConfig({int timeoutSeconds = 5}) => HttpConfig(
        userAgent: userAgent,
        allowNonFlclashUa: true, // R4.4：解除 flclash 强校验（订阅协议已解耦）
        allowBadCertificate: allowBadCertificate, // 证书全放行（与 release dio 同策略）
        connectTimeoutSeconds: timeoutSeconds,
        receiveTimeoutSeconds: timeoutSeconds,
        sendTimeoutSeconds: timeoutSeconds,
      );
}

/// 构造自建隔离放行 dio：直连（findProxy=DIRECT）+ 证书全放行 + bytes 响应。
///
/// [timeout] 连接 / 接收超时（bootstrap 用 5s，加密订阅密文较大用 15s）。
///
/// **R4.4 UA 伪装**：默认 header 注入 [XboardUserAgent.current]（按平台真实浏览器 UA），
/// 让 config.json 拉取 / 加密订阅拉取 / 未来软件更新都混入正常 HTTPS 流量躲 GFW 浅层 UA 检测。
Dio buildReleasedIsolatedDio({required Duration timeout}) {
  final dio = Dio(BaseOptions(
    connectTimeout: timeout,
    receiveTimeout: timeout,
    // bytes 拿原始字节，不让 dio 按 Content-Type 自动 parse；自行解 BOM/UTF-8/JSON。
    responseType: ResponseType.bytes,
    followRedirects: true,
    maxRedirects: 5,
    // R4.4：浏览器 UA 伪装（统一策略 SSoT）。
    headers: {'User-Agent': XboardReleaseHttp.userAgent},
  ));
  dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    // ⚠️ 证书全放行（统一策略 SSoT XboardReleaseHttp.allowBadCertificate，见类注释）。
    client.badCertificateCallback = (cert, host, port) =>
        XboardReleaseHttp.allowBadCertificate;
    client.findProxy = (uri) => 'DIRECT'; // 直连，不走 FlClash 代理。
    return client;
  });
  return dio;
}
