/// Bootstrap 系统常量（R15.A / D58 / D59）。
library;

/// AES-256-GCM AAD（附加认证数据），固定串（R15.A.1）。
/// 解密时必须与加密端一致，否则 GCM tag 校验失败 → 视该来源不可用。
const String kBootstrapAad = 'xboard-bootstrap-v1';

/// Bootstrap 本地缓存 key（DD-22 v1；存外层 envelope 密文，不存明文 R15.D.25/D.28）。
const String kBootstrapCacheKey = 'xb_bootstrap_cache_v1';

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
