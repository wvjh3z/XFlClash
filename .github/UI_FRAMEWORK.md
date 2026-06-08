# MyClient 形态 A · UI 框架参考

> 适用范围：`lib/xboard/` 自有 UI 层（形态 A 商业客户端 MyClient）。
> 设计真源：spec `xboard-form-a-ui-revamp` 原型 `prototype/full.html`(CSS) + `full.js`(各屏渲染)。
> 本文档为「加页面 / 改页面」时的组件与 token 速查表，避免散改、避免重复造轮子。

## 0. 分层总览

```
lib/xboard/widgets/
├── xb_theme.dart        设计 token（XbTokens）+ ThemeData 工厂（buildXbTheme）+ 导航辅助
├── xb_ui_kit.dart       品牌主题注入 + 脚手架 + 原子组件（按钮/输入框/徽标）
├── xb_components.dart    组合组件库（卡片/列表/状态卡/横幅/说明弹窗 等 20+）
├── xb_feedback.dart     反馈辅助（toast / confirm / 品牌色）
├── xb_async_view.dart    异步四分支视图（行为层）
├── xb_submit_guard.dart  提交守卫 mixin（行为层）
├── xb_cooldown_guard.dart 验证码冷却 mixin（行为层）
├── xb_center_toast.dart  屏幕中央浮层提示
└── xboard_consent_dialog.dart 隐私同意弹窗
lib/xboard/shell/sheets/
└── sheet_scaffold.dart  认证 sheet 外壳 + 邮箱/验证码字段
lib/xboard/util/
└── format.dart          金额/流量/日期/百分比格式化
```

**设计原则**
- 视觉一致：所有外观经 token / 组件 / 主题，不在页面里散写颜色尺寸。
- 可被品牌色驱动：flavor 换 `brandColor` → 全局强调色随动。
- a11y：textScaleFactor 1.5/2.0 不溢出、WCAG AA 对比度。
- 自包含：不依赖 FlClash 内部 widget，避免上游同步破坏。
- 设计语言演进只动框架内部（token / 主题 / 组件），调用方页面不动。

---

## 1. 设计 Token（`XbTokens` · xb_theme.dart）

### 1.1 颜色 — 中性底色族（随亮/暗主题切换，`XbTokens.of(context)`）
| 字段 | 含义 | 原型 CSS |
|---|---|---|
| `sf` | 页面背景 | `--sf` |
| `sf2` | 纯白面（sheet / 连接球核心） | `--sf2` |
| `card` | 卡片底 | `--card` |
| `sfc` | 容器 / 分段槽 / 输入框填充 | `--sfc` |
| `on` | 正文 | `--on` |
| `onv` | 次要文字 | `--onv` |
| `line` | 边框 | `--line` |
| `hair` | 细分隔线 | `--hair` |
| `onWarn` | 琥珀柔底卡上的正文色（随亮度） | `--on-warn` |
| `onOk` | 绿柔底卡上的正文色（随亮度） | `--on-ok` |
| `shadow1` / `shadow2` | 普通卡 / 强调卡阴影 | `--sd1` / `--sd2` |

### 1.2 语义状态色（静态常量 `XbTokens.xxx`，浅深通用）
| 常量 | 用途 |
|---|---|
| `XbTokens.ok` `#16A34A` | 成功 / 已完成 / 已连接 |
| `XbTokens.warn` `#E08A1E` | 告警 / 流量将尽 / 待支付 |
| `XbTokens.bad` `#DC3B2C` | 错误 / 已取消 / 高延迟 |
| `XbTokens.info` `#2563EB` | 信息 |
| `XbTokens.conn` `#10B981` | 已连接绿（连接球语义，备用） |

> 品牌强调色不在 token，取自 `Theme.of(context).colorScheme.primary` 或 `xbBrandColor()`。

### 1.3 间距（8pt grid）
`s1=4` `s2=8` `s3=12` `s4=16` `s5=20` `s6=24`

### 1.4 圆角（收敛 3 档 + 组件别名）
| Token | 值 | 用途 |
|---|---|---|
| `rSm` | 10 | chip / tag / 小图标块 |
| `rMd` | 16 | 卡片 / 按钮 / 输入框 / 列表卡（最常用） |
| `rLg` | 22 | 大卡 / 套餐卡 |
| `rSheet` | 30 | sheet 顶圆角 |
| 别名 | → | `rButton`/`rField`/`rCard`/`rCardSmall`=rMd，`rChip`=rSm，`rPill`=rMd |

> 改圆角统一改 token，不在组件里写裸数字（历史已踩坑：黄横幅/续费头曾硬编码 13/12，后对齐 rMd=16）。

### 1.5 尺寸
`hButton = hCta = 52`（所有主按钮统一高度）

---

## 2. 主题与脚手架（xb_ui_kit.dart · xb_theme.dart）

| 符号 | 类型 | 作用 |
|---|---|---|
| `buildXbTheme({brandColor, brightness})` | fn | 形态 A 完整 ThemeData：品牌强调 + 中性底 + 全组件子主题。设计真源。 |
| `XbBrandTheme(brandColor, child)` | widget | 子树注入品牌主题。作用域：shell body / sheet 入口 / 页面 push 入口。 |
| `XbBrandScaffold(title, body, {bottomNavigationBar, actions})` | widget | 二级页脚手架：BrandTheme + Scaffold + AppBar 一站封装。新建 push 页用它。 |
| `xbPush<T>(context, page, {brandColor, replace})` | fn | 带品牌主题的页面跳转。 |
| `xbShowDialog<T>({context, brandColor, builder})` | fn | 带品牌主题的对话框。 |

> 新建二级页统一用 `XbBrandScaffold`，不手写 Scaffold+AppBar+主题（重复 5 处已收口）。

---

## 3. 原子组件（xb_ui_kit.dart）

| 组件 | 用途 / 关键参数 |
|---|---|
| `XbPrimaryButton` | 主按钮，loading 态内嵌 spinner。样式吃主题（品牌红/圆角/高52）。 |
| `XbTextField` | 文本输入，样式吃主题。 |
| `XbBrandBadge({icon, size=72})` | 品牌渐变圆角徽标 + 居中图标（登录/注册页头部）。 |
| `XbIconBadge({icon, size=42, radius=rMd, background\|gradient, iconColor, iconSize})` | **方形图标徽标基元**：固定正方形 + 圆角 + 居中图标。`background` 与 `gradient` 互斥。设置项/信息卡/续费头/登录卡通用。 |

---

## 4. 组合组件（xb_components.dart）

### 4.1 容器 / 卡片
| 组件 | 原型 | 说明 |
|---|---|---|
| `XbCard({child, padding, onTap, radius})` | `.card`/`.dcard` | 通用卡片：白底 + 圆角 + 细边 + sd1 阴影。 |
| `XbSectionCard({title, children})` | `.dcard`+`.dt` | 带标题区块卡。 |
| `XbInfoCard({icon, text})` | `.infocard` | 信息提示卡：图标 + 多行说明，淡品牌底。 |
| `XbHairline` | `.sdiv` | 细分隔线。 |

### 4.2 文本 / 标签
| 组件 | 原型 | 说明 |
|---|---|---|
| `XbGroupLabel(text)` | `.grp` | 分组小标题（灰、13px、w600）。 |
| `XbScreenTitle(text)` | `.abar .t` | Tab 顶部大标题（二级页用 AppBar）。 |
| `XbTag(text, {color})` | `.tag`/`.gbtag`/`.ty` | 小圆角彩底标签。 |
| `XbKeyValueRow({label, value, total})` | `.srow`/`.irow` | 键值行；total 变体加粗 + 品牌色大字。 |

### 4.3 列表
| 组件 | 原型 | 说明 |
|---|---|---|
| `XbListRow({icon, label, subtitle, badge, showChevron, onTap})` | `.li` | 列表行：图标方块 + 标签 + 副标题 + 尾部（角标/箭头）。 |
| `XbListCard({rows})` | `.card` 内多 `.li` | 把多个 `XbListRow` 用细分隔线串成一张卡。 |

### 4.4 状态 / 横幅 / 空态
| 组件 | 原型 | 说明 |
|---|---|---|
| `XbSyncBanner({text})` | `.syncbar` | 顶部同步/刷新横幅：琥珀柔底 + spinner + 文案。 |
| `XbStatusCard` | `.statcard` | 状态卡：大图标 + 标题 + 副标题，按状态色柔底。 |
| `XbPendingOrderBanner({subtitle, amountText, cancelling, onPay, onCancel})` | `.pendcard` | 待支付订单横幅：黄框 + 概要 + 取消/支付两按钮。 |
| `XbEmptyState({icon, title, description, actionLabel, onAction})` | `.guestcta` | 居中空态/引导：图标方块 + 标题 + 说明 + 主按钮。 |
| `XbErrorRetry({message, onRetry})` | — | 加载失败重试块：图标 + 文案 + 重试按钮（多页通用）。 |
| `XbSkeletonBar({widthFactor, height, radius})` | `.sk` | Shimmer 骨架占位条。 |

### 4.5 选项 / 操作栏
| 组件 | 原型 | 说明 |
|---|---|---|
| `XbSelectableOption` | `.planopt`/`.pcell` | 套餐/周期选项卡：选中态品牌边 + 淡品牌底 + 可选角标。 |
| `XbBottomActionBar({primaryLabel, primaryIcon, primaryLoading, onPrimary, ...})` | `.dbar` | 二级页底部操作栏：左次按钮 + 右主按钮。 |

### 4.6 说明弹窗（共用）
| 符号 | 原型 | 说明 |
|---|---|---|
| `XbInfoItem({icon, title, desc})` | `.modeexp` 数据 | 说明项数据模型。 |
| `XbInfoSheet({title, subtitle, items})` | `modeInfoSheet`/`groupTypeInfoSheet` | 通用说明 sheet：标题居中 + 副标题 + 一组解释卡（42×42 品牌淡底图标）+ 品牌实心「知道了」。代理模式说明、节点类型说明共用。 |

---

## 5. 认证 Sheet 外壳（shell/sheets/sheet_scaffold.dart）

| 符号 | 说明 |
|---|---|
| `showXbBottomSheet<T>({context, builder})` | 弹出形态 A 风格底部 sheet（圆角 + 拖拽手柄 + 随键盘抬升 + 可滚动 + 自动注品牌主题）。 |
| `XbSheetScaffold({title, children, subtitle, badge, banner, footer})` | sheet 内容外壳：标题 + 可选 banner + 子内容。纯 UI 无 provider 依赖。 |
| `XbSheetBadge({letter\|icon})` | sheet 头部品牌徽标（登录/注册「M」，找回密码图标）。 |
| `XbEmailAccountField({prefixController, suffixes, selectedSuffix, onSuffixChanged})` | 邮箱账号输入：前缀 2/3 + 后缀下拉 1/3；空后缀列表退化为单输入框。 |
| `XbVerifyCodeField({controller, cooldownSeconds, onSend})` | 验证码输入：短框 + 获取按钮（冷却时禁用 + 显秒数）。 |

---

## 6. 行为层 Mixin / 组件

> 批次二「行为层抽象」成果。手写易漏 finally/mounted/cancel 导致卡死或泄漏，故收口为契约组件（均有契约测试锁定）。

### 6.1 `XbAsyncView`（xb_async_view.dart）
异步四分支**纯展示**组件，状态由调用方持有（不绑 Future/Provider，避开 async 边界坑）。
```dart
XbAsyncView(
  loading: !done && !retrying,
  retrying: retrying,            // 优先级最高 → 显示 XbSyncBanner 黄横幅
  error: done ? snap.error : null,
  errorFallback: '加载失败',
  onRetry: _reload,
  builder: (ctx) => <数据态>,
)
```
**契约**：分支优先级固定 `retrying > loading > error > data`；纯函数式无副作用；`XbDomainError` 经 `resolveErrorText` 解析。
**使用方**：plan_list / order_list / reset_traffic / order_payment。

### 6.2 `XbSubmitGuard<T>`（xb_submit_guard.dart）
提交态守卫 mixin。`submitting` 驱动 loading，`runSubmit(action)` 包提交。
**契约**：永远终止（成功/失败/异常都复位）；重入安全；mounted 安全；异常 rethrow。
**使用方**：login/register/forgot sheet、pending_order_section、order_payment。

### 6.3 `XbCooldownGuard<T>`（xb_cooldown_guard.dart）
验证码冷却倒计时 mixin。`cooldownSeconds` 驱动 UI，`startCooldown([n])` / `resetCooldown()`。
**契约**：倒计时自动停；重入不叠加双 timer；立即解锁；mounted 安全；dispose 自动 cancel。
**使用方**：register / forgot sheet。

### 6.4 全局加载遮罩 `xbRunWithLoading`（xb_loading_overlay.dart）
**用途**：按钮点击后需先 `await` 异步（拉数据再跳转 / 提交）时的统一加载反馈。弹一层**淡化半透明
遮罩 + 居中加载卡**覆盖全屏，明确「正在处理」并**物理阻断重复点击**（模态屏障吃掉手势），完成
自动关闭。**替代各按钮内嵌转圈**的零散写法。
```dart
final plans = await xbRunWithLoading(context, () => service.getPlans());
if (!context.mounted) return;
xbPush(context, PlanDetailPage(plan: ...), brandColor: xbBrandColor()); // 遮罩已关后再 push
```
**契约**：重入安全（已有遮罩不叠加第二层）；永远关闭（成功/异常 finally 关）；异常 rethrow 由调用方落地。
**注意**：push 目标页要在 `xbRunWithLoading` **返回之后**做（遮罩用 dialog，finally 会 pop 栈顶，若在 action 内 push 会误 pop 刚 push 的页）。
**使用方**：mine 续费（先拉套餐再跳详情）等「拉数据后跳转」场景。

### 6.5 导航防连点（`xbPush` 内置）
`xbPush` 内置 **500ms 全局节流**：极短时间内的重复 push 视为连点（双击/狂点），只放行第一次，
避免叠跳多层页面（曾出现「续费连点十次跳十层」）。`replace` 不节流（程序主动替换，非连点）。
调用方无需关心，所有 `xbPush` 跳转自动免疫连点。

---

## 7. 反馈与格式化辅助

### 7.1 反馈（xb_feedback.dart）
| 符号 | 说明 |
|---|---|
| `xbBrandColor()` | 取当前 flavor 品牌色。 |
| `xbToast(context, message)` | 顶部/底部轻提示。 |
| `xbConfirm(context, {title, message, confirmLabel, cancelLabel, destructive})` | 二次确认对话框，返回 `Future<bool>`。 |
| `XbCenterToast`（xb_center_toast.dart） | 屏幕中央浮层提示（连接拦截等）。 |

### 7.2 格式化（util/format.dart）
| 函数 | 输出 |
|---|---|
| `xbYuan(double)` | `¥40.00` |
| `xbYuanMinus(double)` | `-¥5.00` |
| `xbGb(int bytes)` | `0.0`（GB，1 位小数） |
| `xbDate(DateTime)` | `2026-06-05` |
| `xbDateTime(DateTime)` | `2026-06-05 12:30` |
| `xbPercentInt(double 0~1)` | `98`（整数百分比） |

---

## 8. 新增/修改页面的约定

1. **脚手架**：二级 push 页用 `XbBrandScaffold`；Tab 内页面顶部用 `XbScreenTitle`。
2. **异步加载**：用 `XbAsyncView` 统一 loading/retrying/error/data 四态，别手写 FutureBuilder 分支。
3. **提交动作**：State 混入 `XbSubmitGuard`，按钮 loading 用 `submitting`，提交包 `runSubmit`。
4. **点击后需先拉数据再跳转**：用 `xbRunWithLoading(context, action)` 包异步段（淡化遮罩 + 防连点），返回后再 `xbPush`。不要在按钮里自己写 `_busy` + 转圈。
5. **页面跳转**：一律 `xbPush`（已内置 500ms 防连点节流），不裸用 `Navigator.push`。
4. **验证码冷却**：混入 `XbCooldownGuard`，别手写 Timer。
5. **颜色/圆角/间距**：一律用 `XbTokens`，不写裸数字裸色值。
6. **图标方块**：用 `XbIconBadge`，不手写 Container+BoxDecoration+Icon。
7. **金额/日期/流量**：用 `util/format.dart`，不在页面里 `toStringAsFixed`。
8. **弹窗**：说明类用 `XbInfoSheet`；确认类用 `xbConfirm`；认证类用 `XbSheetScaffold`。
9. **验证**：改完 `flutter analyze lib/xboard` → 视觉变更跑 golden（`--update-goldens`）→ 三守卫。

---

## 9. 测试基线（契约/golden）

| 测试 | 覆盖 |
|---|---|
| `test/xboard/widgets/xb_async_view_test.dart` | 异步四分支 8 契约 |
| `test/xboard/widgets/xb_submit_guard_test.dart` | 提交守卫 5 契约 |
| `test/xboard/widgets/xb_cooldown_guard_test.dart` | 冷却 4 契约 |
| `test/xboard/widgets/xb_icon_badge_test.dart` | 图标徽标 4 契约 |
| `test/xboard/widgets/xb_loading_overlay_test.dart` | 全局加载遮罩（显示/重入/异常关闭）3 契约 |
| `test/xboard/golden/pages_golden_test.dart` | 套餐列表/订单/重置/我的(已登录·失败·游客) |
| `test/xboard/golden/home_states_golden_test.dart` | 首页游客/未连接/已连接 |
| `test/xboard/golden/a11y_golden_test.dart` | 套餐详情/支付页 × light/dark × 1.0/1.5/2.0 + 对比度 |

> 视觉改动后用 `--update-goldens` 刷新 baseline；golden 不带 update 跑通 = 像素零变化（用于验证「纯重构不改外观」）。
