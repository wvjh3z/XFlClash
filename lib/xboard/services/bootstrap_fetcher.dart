/// Bootstrap 远端拉取（R15.H.40 / D60 / θ-1）—— 异步阶段（runApp 后 fire-and-forget）。
///
/// **自建独立 dio + IOHttpClientAdapter**（D60 / F76）：启动早期 globalState.attach 未完成，
/// FlClashHttpOverrides.findProxy 访问未就绪运行时 ClashConfig 会抛 LateInitializationError。
/// 自建 adapter 覆盖 findProxy=DIRECT 绕过。
///
/// **⚠️ 证书校验全放行（用户 override，2026-06-01 知情决策）**：原 θ-1 约束要求 bootstrap 拉取
/// 走严格 TLS（`badCertificateCallback=null`）以挡明网 MITM。**用户已知晓全放行会带来明网 MITM
/// 风险（可能泄漏用户登录凭据），仍决定与 FlClash 上游一致全放行**（`=> true`）。本类据此放行
/// 任意证书。安全影响见 SECURITY.md「Bootstrap TLS 全放行」+ design 决策 #12 修订。
///
/// **服务端响应格式宽容解析（W5 修订，"只认内容不挑包装"）**：
/// 客户端把响应字节经一条多档兼容 pipeline 抽出 envelope，**安全契约（AES-256-GCM / nonce 12B
/// 拼前 / AAD `xboard-bootstrap-v1`）保持铁律不放宽**——所有宽容只在外层包装。
///
/// HTTP 层兼容：
/// - 任意 `Content-Type`（`application/json` / `application/octet-stream` / `text/plain` / `text/html` 等）
/// - `Content-Disposition: attachment`（浏览器触发下载，HTTP 客户端透明）
/// - 自动跟随 3xx 重定向（dio 默认）+ gzip/deflate 解压（dio 默认）
/// - 单镜像瞬时超时**重试一次**再放弃（应对网络抖动）
///
/// 编码 / BOM：
/// - UTF-8 BOM（`EF BB BF`，Windows 记事本默认）剥除
/// - UTF-16 LE/BE BOM（`FF FE` / `FE FF`）剥除并转 UTF-8
/// - 首尾空白 / 换行 trim
///
/// 内容形态识别（按优先级 fall-through）：
/// 1. **`json_envelope`**: 标准 JSON `{schema_version, encrypted}`（字段名大小写不敏感 + 别名
///    `version`/`v`/`payload`/`data`/`cipher`）
/// 2. **`html_wrapped`**: HTML/XML 包裹（CDN 错误页 / `<pre>...</pre>`），用宽松正则提取 base64/JSON
/// 3. **`jsonp_wrapped`**: `callback({...})` JSONP 包装，剥外层
/// 4. **`raw_base64`**: 裸 base64 串（含 PEM 风格分行 / URL-safe `-_` 变体 / 缺 padding 自动补齐）
/// 5. **`quoted_base64`**: 被双引号包裹的 base64（`"abc..."`）
///
/// hex 路径**不开**：hex 字符是 base64 子集，视觉重叠无法稳定区分；真实 envelope 默认 base64。
///
/// 安全护栏（密码学层**不**放宽，第三档危险项不做）：
/// - AAD 必须 `xboard-bootstrap-v1`，nonce 必须 12B 拼前，GCM tag 必须校验通过
/// - 不接受明文 endpoint 列表（不绕 D58 加密）
/// - 不接受不同 nonce 长度 / 位置（不让攻击者"试到一种成功"）
///
/// **可追溯**：每条成功识别路径打 Sentry tag `bootstrap.parse_path`（DD-23 扩展）便于事后排查。
///
/// **串行 + 30s 总预算**（R15.B.4/B.6）：串行尝试所有镜像，单镜像 5s 超时，总 30s 预算；
/// 全失败降级沿用本地 endpoint（不阻塞首屏）。永不抛（Property 1）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config/bootstrap_constants.dart';
import '../models/bootstrap_envelope.dart';
import '../models/bootstrap_payload.dart';
import 'bootstrap_decryptor.dart';
import 'sentry_bootstrap.dart';
import 'xboard_release_dio.dart';

/// 单个响应字节解析的中间结果（envelope + 识别路径，供 Sentry tag 追溯）。
///
/// R4.1/R4.2：加密订阅复用 [BootstrapFetcher.parseEnvelopeBytes]（同款多档宽容解析），故本类
/// 与该方法已从 `@visibleForTesting` 提升为 `lib/xboard` 内共享公共 API。
class BootstrapParseResult {
  const BootstrapParseResult(this.envelope, this.parsePath);
  final BootstrapEnvelope envelope;
  final String parsePath;
}

/// 远端拉取结果（成功携 payload + 命中镜像；失败为 null payload）。
class BootstrapFetchResult {
  const BootstrapFetchResult({
    this.payload,
    this.winnerUrl,
    this.winnerEnvelope,
    this.parsePath,
    this.lastFailure,
  });

  final BootstrapPayload? payload;
  final String? winnerUrl;

  /// 命中镜像的外层 envelope（成功时供 [BootstrapLocalLoader.writeCache] 写缓存密文）。
  final BootstrapEnvelope? winnerEnvelope;

  /// 命中镜像的解析路径标签（如 `json_envelope` / `raw_base64`，供 Sentry 追溯）。
  final String? parsePath;

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

  /// 自建隔离 dio：直连 + 证书全放行（用户 override，见类注释）+ 5s 连接超时 + bytes 响应。
  static Dio _buildIsolatedDio() =>
      buildReleasedIsolatedDio(timeout: kBootstrapPerMirrorTimeout);

  /// 串行尝试所有 [mirrors]，30s 总预算；首个解出有效 payload 的镜像胜出。
  /// 全失败 → payload=null（调用方沿用本地 endpoint）。永不抛。
  Future<BootstrapFetchResult> fetchRemote(List<String> mirrors) async {
    final deadline = DateTime.now().add(kBootstrapTotalBudget);
    BootstrapDecryptFailure? lastFailure;

    for (final url in mirrors) {
      if (DateTime.now().isAfter(deadline)) break; // 30s 总预算耗尽。
      try {
        final bytes = await _fetchBytesWithRetry(url);
        if (bytes == null) continue;

        final parsed = parseEnvelopeBytes(bytes);
        if (parsed == null) continue; // 任意宽容路径都识别不出 envelope，下一镜像。

        final result = await _decryptor.decryptAndValidate(parsed.envelope);
        if (result.isSuccess) {
          // DD-23：远端拉取成功 → envelope_source=remote + parse_path（W5.7 / 5.7.2 扩展）。
          SentryBootstrap.tagBootstrap(
            stage: 'remote_fetched',
            envelopeSource: 'remote',
          );
          SentryBootstrap.setTag('bootstrap.parse_path', parsed.parsePath);
          return BootstrapFetchResult(
            payload: result.payload,
            winnerUrl: url,
            winnerEnvelope: parsed.envelope,
            parsePath: parsed.parsePath,
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

  /// 单镜像拉取 + 一次重试（应对瞬时超时）。失败返 null，永不抛。
  Future<Uint8List?> _fetchBytesWithRetry(String url) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        // per-request 显式 bytes（生产 dio 已默认 bytes；测试注入的 dio 可能是默认 json，
        // 这里强制覆盖保证宽容解析的字节路径生效）。
        final resp = await _dio.getUri<List<int>>(
          Uri.parse(url),
          options: Options(responseType: ResponseType.bytes),
        );
        final code = resp.statusCode ?? 0;
        if (code < 200 || code >= 300) return null;
        final data = resp.data;
        if (data == null || data.isEmpty) return null;
        // 大小护栏：> 10MB 视为异常（R15 envelope 通常 < 1KB；此放宽限给极端情况留余地）。
        if (data.length > 10 * 1024 * 1024) return null;
        return Uint8List.fromList(data);
      } on DioException catch (e) {
        // 仅对瞬时网络问题重试；其他错误（4xx/5xx 已被 statusCode 分支拦截）直接放弃。
        final transient = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.connectionError;
        if (!transient || attempt == 1) return null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 把原始字节宽容解析为 [BootstrapEnvelope]（公共静态方法，便于单测穷举各种格式）。
  ///
  /// 解析顺序见类注释「内容形态识别」。识别成功携 [BootstrapParseResult.parsePath]（Sentry tag）；
  /// 全部识别策略失败返 null。**安全契约不动**——本方法只产出 envelope，加密格式校验仍由
  /// [BootstrapDecryptor] 严格执行。
  ///
  /// R4.1/R4.2：加密订阅 [EncryptedSubscriptionService] 复用本方法抽 envelope（已从
  /// `@visibleForTesting` 提升为 `lib/xboard` 内共享公共 API）。
  static BootstrapParseResult? parseEnvelopeBytes(Uint8List bytes) {
    // 1. 剥 BOM + 解 UTF-8（容错替换非 UTF-8 字节，不在外层包装上报错）。
    final stripped = _stripBom(bytes);
    String text;
    try {
      text = utf8.decode(stripped, allowMalformed: true);
    } catch (_) {
      // 极端情况：非 UTF-8 也无法 latin1 解 → 试当 ASCII 处理（base64/hex 都是 ASCII 子集）。
      text = String.fromCharCodes(stripped);
    }
    text = text.trim();
    if (text.isEmpty) return null;

    // 2. 优先级一：标准 JSON envelope（含字段别名 + 大小写不敏感）。
    final asJson = _tryParseJsonEnvelope(text);
    if (asJson != null) return BootstrapParseResult(asJson, 'json_envelope');

    // 3. JSONP 包装（`callback(...)`）。
    final unjsonp = _tryUnwrapJsonp(text);
    if (unjsonp != null) {
      final asJsonAfter = _tryParseJsonEnvelope(unjsonp);
      if (asJsonAfter != null) return BootstrapParseResult(asJsonAfter, 'jsonp_wrapped');
    }

    // 4. HTML/XML 包裹（CDN 错误页 / <pre>...）：抽出 base64 块。
    final fromHtml = _tryExtractFromHtml(text);
    if (fromHtml != null) {
      final env = _envelopeFromBase64Like(fromHtml);
      if (env != null) return BootstrapParseResult(env, 'html_wrapped');
    }

    // 5. 裸 base64（PEM 分行 / URL-safe / 缺 padding 自动归一）。
    final asB64 = _envelopeFromBase64Like(text);
    if (asB64 != null) return BootstrapParseResult(asB64, 'raw_base64');

    // 6. 双引号包裹的 base64（`"abc..."`）。
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      final unq = text.substring(1, text.length - 1);
      final env = _envelopeFromBase64Like(unq);
      if (env != null) return BootstrapParseResult(env, 'quoted_base64');
    }

    // 注：hex 路径与 base64 视觉重叠（hex 字符是 base64 字符集子集），无法稳定区分；
    // 真实 envelope 几乎全是 base64（cryptography 库默认输出），故不开 hex 兼容。

    return null;
  }

  /// 剥 UTF-8 / UTF-16 LE/BE BOM。
  static Uint8List _stripBom(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      return Uint8List.sublistView(b, 3);
    }
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      // UTF-16 LE → 转 UTF-8（罕见，仅支持 BMP 字符简单转换）。
      return _utf16ToUtf8(b.sublist(2), littleEndian: true);
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return _utf16ToUtf8(b.sublist(2), littleEndian: false);
    }
    return b;
  }

  static Uint8List _utf16ToUtf8(Uint8List src, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < src.length; i += 2) {
      units.add(littleEndian
          ? (src[i] | (src[i + 1] << 8))
          : ((src[i] << 8) | src[i + 1]));
    }
    return Uint8List.fromList(utf8.encode(String.fromCharCodes(units)));
  }

  /// 尝试 JSON envelope（字段名大小写不敏感 + 别名 + schema_version 容忍）。
  static BootstrapEnvelope? _tryParseJsonEnvelope(String text) {
    Object? obj;
    try {
      obj = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (obj is! Map) return null;
    final map = obj; // 局部 final Map（闭包用，避免 Object? 类型穿透）。

    // 大小写不敏感 + 多别名查找。
    String? findStr(List<String> aliases) {
      for (final entry in map.entries) {
        final key = entry.key.toString().toLowerCase();
        if (aliases.contains(key) && entry.value is String) {
          return entry.value as String;
        }
      }
      return null;
    }

    int? findInt(List<String> aliases) {
      for (final entry in map.entries) {
        final key = entry.key.toString().toLowerCase();
        if (aliases.contains(key)) {
          final v = entry.value;
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v);
        }
      }
      return null;
    }

    final encrypted = findStr(const [
      'encrypted',
      'payload',
      'data',
      'cipher',
      'ciphertext',
    ]);
    if (encrypted == null || encrypted.isEmpty) return null;

    // schema_version 缺失/非法 → 默认 1（外层版本一般稳定，宽容）。
    final ver = findInt(const ['schema_version', 'schemaversion', 'version', 'v']) ?? 1;

    return BootstrapEnvelope(schemaVersion: ver, encrypted: encrypted);
  }

  /// `callback({...})` / `callback([...])` JSONP 剥外层。
  static String? _tryUnwrapJsonp(String text) {
    final m = RegExp(r'^[\s]*[\w$]+\s*\(\s*([\s\S]+)\s*\)[\s;]*$').firstMatch(text);
    if (m == null) return null;
    return m.group(1);
  }

  /// 从 HTML/XML 文本里抽出 JSON 块或 base64 块（CDN 错误页 / `<pre>` 包裹）。
  static String? _tryExtractFromHtml(String text) {
    final lower = text.toLowerCase();
    if (!lower.contains('<') || !lower.contains('>')) return null;
    // 优先抽 <pre>...</pre> / <code>...</code>。
    for (final tag in const ['pre', 'code', 'body', 'p']) {
      final m = RegExp(
        '<$tag[^>]*>([\\s\\S]*?)</$tag>',
        caseSensitive: false,
      ).firstMatch(text);
      if (m != null) {
        final inner = _decodeHtmlEntities(m.group(1)!).trim();
        if (inner.isNotEmpty) return inner;
      }
    }
    // 兜底：剥所有标签。
    final stripped = text.replaceAll(RegExp(r'<[^>]+>'), ' ').trim();
    return stripped.isEmpty ? null : _decodeHtmlEntities(stripped);
  }

  static String _decodeHtmlEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  /// 把任意疑似 base64 文本归一为标准 base64 后构造 envelope。失败返 null。
  static BootstrapEnvelope? _envelopeFromBase64Like(String text) {
    // 去所有空白（PEM 分行 / 多余换行）。
    var s = text.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;
    // URL-safe → 标准。
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    // 补齐 padding。
    final pad = s.length % 4;
    if (pad != 0) s = s + '=' * (4 - pad);
    // 校验字符集。
    if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s)) return null;
    // 试解码（不抛说明合法）。最小长度护栏：12 nonce + 16 tag = 28 字节 = 40 base64 字符。
    try {
      final raw = base64.decode(s);
      if (raw.length < 28) return null;
    } catch (_) {
      return null;
    }
    return BootstrapEnvelope(schemaVersion: 1, encrypted: s);
  }
}
