# Golden 测试 — 规范环境与重生成

形态 A 页面/外壳的 golden 截图测试（首页/节点/我的/套餐/订单/更新弹窗/桌面外壳/a11y）。
用注入数据渲染 → 像素比对，跟原型对齐。不依赖模拟器，可重复、可进 CI。

视觉设计参考见 [当前 HTML 原型](https://github.com/wvjh3z/proxy-suite-docs/blob/main/prototypes/xflclash/README.md)；原型源已迁出旧 spec 仓库，golden 基线仍由本目录和对应测试维护。Docs 为私有仓库，需要维护者授予 GitHub 访问权限；本地 checkout 路径为客户端平级的 `Docs/`。

## ⚠️ golden 像素对环境敏感（务必读）

golden 是**像素级**比对，渲染结果取决于 **Flutter/引擎版本 + 字体**。环境不一致 → 整批 diff
（diff 比例随文本量递增是其指纹）。本目录的基线锚定在**唯一规范环境**：

| 维度 | 规范值 |
|---|---|
| 平台 | Linux |
| Flutter | **3.44.0**（stable；`flutter --version` 核对）|
| CJK 字体 | 系统 **Noto CJK**（`/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`，由 `_loadCjkFont` 加载）|
| emoji 字体 | 仓库打包 `assets/fonts/Twemoji.Mozilla.ttf` |

CI（`.github/workflows/xboard-ci.yml` 的 `analyze-and-test`）已对齐：`flutter-version: 3.44.0`
+ `apt-get install fonts-noto-cjk`。**改 Flutter 版本或字体 → 必须重生成全部基线**。

### 桌面外壳的字体与套餐夹具

`desktop_shell_golden_test.dart` 明确加载 Noto CJK 到测试中的 Roboto 家族，并从
`FontManifest.json` 加载应用字体、Material 图标和 Twemoji。缺少 Noto 会直接失败，
不再静默回退到另一套系统字体；等宽方块字体的度量检查也会阻止错误环境写入基线。

仅加载字体仍不足以覆盖所有文字：品牌主题的部分 TextStyle，以及 EmojiText 的
RichText span 没有指定 fontFamily，Flutter 测试引擎仍会为它们选择方块字体。
`expectDesktopGolden` 在截图前仅给这些 span 补测试字体并重新布局，保留已指定的
图标/emoji 家族与文字、样式、交互和语义。这是截图测试的字体配置，不修改正式
Theme、Widget 或运行时字体。原生窗口截图另用于确认系统字体下的实际显示，不能
把这种确定化的测试截图当成 Linux、Windows 字体完全一致的证明。

默认截图账户使用长期有效套餐（expiredAt/nextResetAt 为 null），避免某个固定
日期到期后，首页告警、节点空态和账号卡随日历变化。已过期套餐另有结构回归，
检查节点空态、续费入口及正常节点隐藏；日期倒计时由专项组件测试承担。

2026-10-13 本轮仅审阅并重生成8张 `desktop_*.png`，覆盖游客三页、已登录三页、
首页未连接及1920×1080首页。其他页面 golden 未在本轮重新审阅或迁移。
本机字体包版本、摘要和实际验证记录见 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#linux-桌面界面验证2026-10-13)。

## 重生成基线

只在规范环境跑（否则会把本机的渲染差异写进基线、害别处失配）：

```bash
flutter test --update-goldens test/xboard/golden
# 重生成后必须不带 --update 再跑一遍确认稳定通过：
flutter test test/xboard/golden
```

只维护桌面外壳时限定范围，审阅 PNG 后再进行第二条不更新基线的检查：

```bash
flutter test --no-pub --update-goldens test/xboard/golden/desktop_shell_golden_test.dart
flutter test --no-pub test/xboard/golden/desktop_shell_golden_test.dart
```

## 看不懂某个 golden 失败？

1. 失败图落在 `test/xboard/golden/failures/`（`*_testImage.png` 本次渲染 / `*_masterImage.png`
   基线 / `*_maskedDiff.png` 差异）。先对比看是「真实 UI 变化」还是「渲染漂移」。
2. **真实 UI 变了**（改了页面）→ 重生成基线（上面命令）。
3. **渲染漂移**（环境不符）→ 别重生成，先把环境对齐到上表规范值。
4. 结构类断言（`find...` / 无溢出 / 对比度）失败 ≠ 像素失配：
   - `find.text` 默认**不匹配 RichText**（`EmojiText` 即 RichText）→ 用 `find.text(s, findRichText: true)`。

## 历史

- 2026-06-27：全量基线在规范环境（Linux / Flutter 3.44.0 / Noto CJK）重生成，修复跨环境像素漂移；
  CI 锁 Flutter 版本 + 装 fonts-noto-cjk 确定化；新增本说明。
- 2026-10-13：桌面复查发现原基线仍包含方块文字，且固定套餐日期已到期；
  修正截图字体、稳定套餐夹具，审阅并更新8张桌面基线，其他基线保持原状。
