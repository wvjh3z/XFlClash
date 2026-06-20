# 安全说明（XFlClash fork — Xboard 模块）

本文件记录本 fork 的 Xboard 模块（`lib/xboard/`）相关的安全设计与**已知风险接受决策**。
FlClash 上游自身的安全策略见上游仓库。

---

## 已知风险：全部管理流量 TLS 证书全放行（含登录凭据）

**状态**：⚠️ 已接受（用户知情决策；Bootstrap 2026-06-01，扩展到全部管理流量 2026-06-19）

### 决策记录

**2026-06-01（Bootstrap）**：原设计（θ-1 / 决策 #12）要求 Bootstrap 远端拉取走**严格 TLS 校验**。
负责人在充分知情下决定改为**证书全放行**，与 FlClash 上游全局 `HttpOverrides`（`badCertificateCallback => true`）一致。

**2026-06-19（扩展到全部管理流量）**：负责人决策「相比安全性，优先可用性」，把证书全放行
**扩展到所有 Xboard 出站管理流量**——包括 **SDK API 通道（登录 / 注册 / 账号 / 套餐 / 订单 / 支付 / 版本检查）**。

负责人确认原话：
> "相比于安全性，我优先考虑可用性。API endpoint / config.json 证书也放行。"

**原因**：config.json 下发的 endpoint 可能是**裸 IP**（无匹配证书），标准 TLS 校验必失败 → 连不上；可用性优先于 TLS 身份保护。

**实现（框架化，单一来源 SSoT）**：
- 客户端 `XboardReleaseHttp`（`lib/xboard/services/xboard_release_dio.dart`）集中「UA 伪装 + 证书放行 + 直连」策略，两条通道共用：
  - **release dio**（config.json / 加密订阅 / 软件更新下载）：`badCertificateCallback => true`。
  - **SDK HttpService**（登录/账号/订单/支付/版本检查）：`HttpConfig.allowBadCertificate=true`（SDK **v1.18.0**），自建 adapter `badCertificateCallback => true`。
- `enableCertificatePinning` 启用时仍走严格 pinning（不被本放行绕过）。

### 风险说明

- 管理流量在 VPN 隧道建立**之前 / 之外**走明网直连，TLS 校验是身份**唯一**防线；全放行后恶意 WiFi / 运营商劫持 / DNS 污染可冒充服务端 MITM。
- ⚠️ **登录 / 账号通道现也全放行**（2026-06-19 新增暴露面，原仅 Bootstrap）→ 用户邮箱 / 密码 / token 在明网 MITM 下理论上可被截获或篡改。
- **缓解层不对称**：能 AES-256-GCM 校验的内容（config.json envelope / 加密订阅密文）仍有**完整性保护**（无 AES key 不可伪造）；但**纯 API 请求（登录等）无此加密层**，TLS 关闭后无身份/完整性防线。

### 影响范围（2026-06-19 订正）

- **两条出站通道全部证书放行**：
  - release dio：`lib/xboard/services/xboard_release_dio.dart`（`buildReleasedIsolatedDio` 的 `badCertificateCallback`）
  - SDK HttpService：经 `XboardReleaseHttp.sdkHttpConfig()` 注入 `allowBadCertificate`（SDK `lib/src/core/http/http_service.dart`）
- ⚠️ **订正旧表述**：此前本节写「SDK 业务 API 走 FlClash 既有 `HttpOverrides`，本就全放行」——**不准确**。SDK 用**自建 `IOHttpClientAdapter`**（不继承 FlClash `HttpOverrides`），且 2026-06-19 之前是**标准 TLS 校验**（非全放行）；现经 `allowBadCertificate` 显式放行。

### 恢复安全的建议路径（优先级递增）

1. 仅对特定主机 / 证书指纹放行（cert pinning 白名单），其余严格；**尤其登录 / 账号凭据通道优先恢复严格**。
2. 后端裸 IP 端点改配有效证书的域名 → 可对 API 通道恢复严格 TLS（订阅/bootstrap 若仍用裸 IP 则保留放行）。

---

## Bootstrap envelope 加密（D58，保留）

- Bootstrap JSON 内容用 **AES-256-GCM** 加密；客户端编译期经 dart-define 注入 flavor 对应 AES key（32 字节 base64）。
- 布局：`base64( nonce(12B) || ciphertext || tag(16B) )`；AAD 固定 `xboard-bootstrap-v1`。
- AES key **绝不进 git**（D58 / conventions §7.1）：仓库内占位空值，build 时经 CI secrets / 本地 `flavor_defines.json`（gitignored）注入。
- nonce 每次加密随机生成、随密文传输（公开，不保密、不写死在客户端）。

## Token 存储

- 移动端：`flutter_secure_storage` + Android `EncryptedSharedPreferences`（θ-10）；`allowBackup=false` 防卸载重装残留。
- Linux 桌面无 D-Bus / gnome-keyring 时降级 AES-256-GCM 加密 SharedPreferences（ζ1）。
