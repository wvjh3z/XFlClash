/// R4.8 手动救援通道 —— 用户手动导入应急 config 密文（终极兜底）。
///
/// **场景**：所有自动恢复路径都失效（bootstrapUrls 全挂 + R4.7 自举地址也挂 + 本地缓存/
/// fallback endpoint 全失效）→ 用户经外部渠道（客服 / 官网 / 社群）拿到应急 config 密文，
/// 手动粘贴 / 扫码导入。解出有效 endpoint 后写本地缓存（等价「手动喂了一次 config.json」），
/// 下次冷启动即从缓存恢复。
///
/// **复用 bootstrap 解密链路**（零新增密码学）：与远端 config.json 同形态 envelope
/// `{schema_version, encrypted}` → 同套 AES-256-GCM 解密（AAD `xboard-bootstrap-v1`）。
///
/// **永不抛**（Property 1）：任何失败返 [ManualImportResult.failure]，UI 据 reason 提示。
library;

import 'dart:convert';

import '../models/bootstrap_envelope.dart';
import 'bootstrap_decryptor.dart';
import 'bootstrap_local_loader.dart';

/// 手动导入失败原因（UI 文案分流）。
enum ManualImportFailure {
  /// 输入为空。
  empty,

  /// 不是合法 JSON / 缺 schema_version|encrypted 字段（不是 config 密文格式）。
  malformedInput,

  /// 解密 / 校验失败（密钥不匹配 / 数据损坏 / endpoint 为空）。
  decryptFailed,
}

/// 手动导入结果。
class ManualImportResult {
  const ManualImportResult._(this.ok, this.failure, this.apiCount, this.subCount);

  factory ManualImportResult.success({required int apiCount, required int subCount}) =>
      ManualImportResult._(true, null, apiCount, subCount);
  factory ManualImportResult.failure(ManualImportFailure failure) =>
      ManualImportResult._(false, failure, 0, 0);

  final bool ok;
  final ManualImportFailure? failure;

  /// 成功时解出的 endpoint 数量（供 UI 反馈「已导入 N 个线路」）。
  final int apiCount;
  final int subCount;
}

/// 手动导入服务（注入解密器 + 本地加载器便于测试）。
class BootstrapManualImport {
  BootstrapManualImport({
    required BootstrapDecryptor decryptor,
    required BootstrapLocalLoader loader,
  })  : _decryptor = decryptor,
        _loader = loader;

  final BootstrapDecryptor _decryptor;
  final BootstrapLocalLoader _loader;

  /// 导入用户粘贴的 config 密文文本（完整 `{schema_version, encrypted}` JSON）。
  ///
  /// 成功 → 写缓存（envelope 密文 + next_bootstrap_urls）+ 返 success。永不抛。
  Future<ManualImportResult> importFromText(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) {
      return ManualImportResult.failure(ManualImportFailure.empty);
    }

    // 1. 解析外层 envelope JSON。
    BootstrapEnvelope envelope;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return ManualImportResult.failure(ManualImportFailure.malformedInput);
      }
      // 必须含 encrypted 字段（schema_version 缺则按容错默认，fromJson 处理）。
      if (decoded['encrypted'] is! String ||
          (decoded['encrypted'] as String).trim().isEmpty) {
        return ManualImportResult.failure(ManualImportFailure.malformedInput);
      }
      envelope = BootstrapEnvelope.fromJson(decoded);
    } catch (_) {
      return ManualImportResult.failure(ManualImportFailure.malformedInput);
    }

    // 2. 解密 + 校验（同 bootstrap 链路）。
    final result = await _decryptor.decryptAndValidate(envelope);
    if (!result.isSuccess || result.payload == null) {
      return ManualImportResult.failure(ManualImportFailure.decryptFailed);
    }
    final payload = result.payload!;

    // 3. 写本地缓存（等价手动喂一次 config.json）+ next_bootstrap_urls 滚动（R4.7 联动）。
    await _loader.writeCache(envelope);
    await _loader.writeNextBootstrapUrls(payload.nextBootstrapUrls);

    return ManualImportResult.success(
      apiCount: payload.apiUrls.length,
      subCount: payload.subscriptionUrls.length,
    );
  }
}
