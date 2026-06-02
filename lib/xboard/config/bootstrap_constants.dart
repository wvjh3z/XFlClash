/// Bootstrap 系统常量（R15.A / D58 / D59）。
library;

/// AES-256-GCM AAD（附加认证数据），固定串（R15.A.1）。
/// 解密时必须与加密端一致，否则 GCM tag 校验失败 → 视该来源不可用。
const String kBootstrapAad = 'xboard-bootstrap-v1';

/// R4.1 加密订阅 AAD（与 [kBootstrapAad] 区分，防跨用途重放，contract 0-B / 后端 EncryptedSubscribe v1.0.2）。
/// 加密订阅密文（ClashMeta YAML）解密时用此 AAD；密码学其余约定（AES-256-GCM / nonce 12B 拼前 /
/// tag 16B）与 bootstrap 完全一致，故复用 [BootstrapDecryptor]（仅 AAD 参数不同）。
const String kEncryptedSubscriptionAad = 'xboard-encrypted-sub-v1';

/// R4.1 加密订阅子路径片段：在原订阅 URL `https://host/{path}/{token}` 的 `/{token}` 前插入
/// 本片段 → `https://host/{path}/encrypted/{token}`（contract 0-B「方案 b」，无需知 subscribe_path）。
const String kEncryptedSubscriptionPathSegment = 'encrypted';

/// R4.1 加密订阅单次拉取超时（密文 ~数十 KB，比 config.json envelope 大，给足余量）。
const Duration kEncryptedSubscriptionTimeout = Duration(seconds: 15);

/// Bootstrap 本地缓存 key（DD-22 v1；存外层 envelope 密文，不存明文 R15.D.25/D.28）。
const String kBootstrapCacheKey = 'xb_bootstrap_cache_v1';

/// R4.7 地址自举：缓存的 next_bootstrap_urls（明文 JSON 字符串数组）。
/// 下次冷启动加载 bootstrapUrls 时优先用（缓存 > 编译期 flavor bootstrapUrls）。
/// 只存 URL 列表（非密文，非敏感；scheme 白名单 https 校验后才写）。
const String kNextBootstrapUrlsKey = 'xb_next_bootstrap_urls_v1';

/// 出厂 fallback 资产路径（随包必带，R15.B-extra.9）。
const String kBootstrapFallbackAsset = 'assets/xboard/bootstrap_fallback.json';

/// 单镜像拉取超时（R15.B.5）。
const Duration kBootstrapPerMirrorTimeout = Duration(seconds: 5);

/// 远端阶段总预算（R15.B.6）。
const Duration kBootstrapTotalBudget = Duration(seconds: 30);

/// endpoint 竞速：30 分钟滚动窗口内累计切换 ≥ 此值 → 重新完整竞速（R15.C.19）。
const int kEndpointReraceThreshold = 5;

/// endpoint 切换计数滚动窗口（R15.C.19）。
const Duration kEndpointRaceWindow = Duration(minutes: 30);
