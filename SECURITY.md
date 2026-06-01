# 安全说明（XFlClash fork — Xboard 模块）

本文件记录本 fork 的 Xboard 模块（`lib/xboard/`）相关的安全设计与**已知风险接受决策**。
FlClash 上游自身的安全策略见上游仓库。

---

## 已知风险：Bootstrap TLS 证书全放行

**状态**：⚠️ 已接受（用户知情决策，2026-06-01）

### 决策记录

原设计（θ-1 / 决策 #12）要求 Bootstrap 远端拉取（`lib/xboard/services/bootstrap_fetcher.dart`）
走**严格 TLS 校验**（`badCertificateCallback = null`），以挡明网中间人攻击（MITM）。

项目负责人在充分知情下决定**改为证书全放行**（`badCertificateCallback => true`），
与 FlClash 上游全局 `HttpOverrides`（`badCertificateCallback => true`）保持一致。

负责人确认原话：
> "我已知晓 bootstrap 全放行证书会带来明网 MITM 风险（可能泄漏用户登录凭据），仍决定与上游一致全放行。"

### 风险说明

- Bootstrap 拉取发生在 VPN 隧道建立**之前**（启动早期，明网直连），TLS 校验是该链路**唯一**的身份防线。
- 全放行后，恶意 WiFi / 运营商劫持 / DNS 污染节点可冒充 Bootstrap 镜像，下发伪造 envelope。
- envelope 内含真实后端地址，客户端连上后传输用户登录邮箱 / 密码 / token；明网 MITM 可能截获或诱导。
- AES-256-GCM 加密（D58）仍是第二道防线：攻击者无 AES key 无法解出 / 伪造合法 envelope 内容；
  但 TLS 校验这第一道防线已关闭。

### 缓解现状

- Bootstrap envelope 内容仍 **AES-256-GCM 加密 + AAD 认证**（D58），未泄漏 AES key 时伪造 envelope 不可行。
- 后续如需恢复安全，建议路径（优先级递增）：
  1. 仅对特定主机/证书指纹放行（cert pinning 白名单），其余严格；
  2. 恢复严格 TLS，后端裸 IP 端点改配有效证书的域名。

### 影响范围

- 文件：`lib/xboard/services/bootstrap_fetcher.dart`（`_buildIsolatedDio` 的 `badCertificateCallback`）
- 不影响：SDK 业务 API 调用走 FlClash 既有 `HttpOverrides`（本就全放行，与上游一致）。

---

## Bootstrap envelope 加密（D58，保留）

- Bootstrap JSON 内容用 **AES-256-GCM** 加密；客户端编译期经 dart-define 注入 flavor 对应 AES key（32 字节 base64）。
- 布局：`base64( nonce(12B) || ciphertext || tag(16B) )`；AAD 固定 `xboard-bootstrap-v1`。
- AES key **绝不进 git**（D58 / conventions §7.1）：仓库内占位空值，build 时经 CI secrets / 本地 `flavor_defines.json`（gitignored）注入。
- nonce 每次加密随机生成、随密文传输（公开，不保密、不写死在客户端）。

## Token 存储

- 移动端：`flutter_secure_storage` + Android `EncryptedSharedPreferences`（θ-10）；`allowBackup=false` 防卸载重装残留。
- Linux 桌面无 D-Bus / gnome-keyring 时降级 AES-256-GCM 加密 SharedPreferences（ζ1）。
