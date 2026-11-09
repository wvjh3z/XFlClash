# Golden 测试 — 规范环境与重生成

形态 A 页面/外壳的 golden 截图测试（首页/节点/我的/套餐/订单/更新弹窗/桌面外壳/a11y）。
用注入数据渲染 → 像素比对，跟原型对齐。不依赖模拟器，可重复、可进 CI。

视觉设计参考见 [当前 HTML 原型](https://github.com/wvjh3z/proxy-suite-docs/blob/main/prototypes/xflclash/README.md)；原型源已迁出旧 spec 仓库，golden 基线仍由本目录和对应测试维护。Docs 为私有仓库，需要维护者授予 GitHub 访问权限；本地 checkout 路径为客户端平级的 `Docs/`。

## ⚠️ golden 像素对环境敏感（务必读）

golden 是**像素级**比对，渲染结果取决于 **Flutter/引擎版本 + 字体 + 页面/夹具源码**。环境、
页面或字体继承变化均可能产生 diff，不能只凭失败数量或名称判定为环境噪声。当前环境由 `environment.json` 唯一固定：

| 维度 | 规范值 |
|---|---|
| 平台 | Linux |
| Flutter / Dart | **3.47.6 / 3.13.5**；引擎完整revision由JSON固定 |
| CJK 字体 | 固定摘要的Noto CJK；优先 `XB_GOLDEN_CJK_FONT`，未设时读取JSON中的系统路径，仍校验摘要 |
| 资产字体 | MaterialIcons、JetBrainsMono、Twemoji；严格校验manifest与每个资产摘要 |

CI（`.github/workflows/xboard-ci.yml`）使用 `tool/prepare_golden_font.py` 将固定来源的字体提取到Runner临时目录，校验后设置 `XB_GOLDEN_CJK_FONT`；不再依赖未固定版本的apt字体包。统一夹具缺字体、摘要/manifest/工具链不符时直接失败。整条CI尚未触发，隔离字体准备及测试证据见下方论证记录。

2026-11-09先完成三方像素论证，再统一8份字体加载器和37张截图入口。用户先批准35张；两张套餐HTML经原型确认、生产配色修复、实际RichText检查与负控后另行获批。全部PNG均复制对应获批审阅图，而非批量消红。历史基线与当前差异、批准清单及复跑结果见[golden论证](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/golden-adjudication.md)。

### 统一字体与套餐夹具

`golden_environment.dart` 明确加载 Noto CJK 到测试中的 Roboto 家族，并从
`FontManifest.json` 加载应用字体、Material 图标和 Twemoji。缺少 Noto 会直接失败，
不再静默回退到另一套系统字体；等宽方块字体的度量检查也会阻止错误环境写入基线。

仅加载字体仍不足以覆盖所有文字：品牌主题的部分 TextStyle，以及 EmojiText 的
RichText span 没有指定 fontFamily，Flutter 测试引擎仍会为它们选择方块字体。
`prepareGoldenFrame` 在截图前仅给这些 span 补测试字体并重新布局，保留已指定和继承的
图标/emoji 家族与文字、样式、交互和语义。这是截图测试的字体配置，不修改正式
Theme、Widget 或运行时字体。原生窗口截图另用于确认系统字体下的实际显示，不能
把这种确定化的测试截图当成 Linux、Windows 字体完全一致的证明。

默认截图账户使用长期有效套餐（expiredAt/nextResetAt 为 null），避免某个固定
日期到期后，首页告警、节点空态和账号卡随日历变化。已过期套餐另有结构回归，
检查节点空态、续费入口及正常节点隐藏；日期倒计时由专项组件测试承担。

2026-10-13 本轮仅审阅并重生成8张 `desktop_*.png`，覆盖游客三页、已登录三页、
首页未连接及1920×1080首页。其他页面 golden 未在本轮重新审阅或迁移。
本机字体包版本、摘要和实际验证记录见 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#linux-桌面界面验证2026-10-13)。

桌面导航栏Logo读取构建期注入的`assets/images/icon.png`。截图夹具必须在真实异步区间预加载图片，单纯推进测试时钟可能截到空白。该套基线刻意使用源码中的未注入开发图标/默认名称；两品牌正式图像的复制一致性由`tool/test/inject_system_icons_cli_test.dart`核验，不用开发截图证明品牌成品已经构建。

## 重生成基线

仅在该批次环境、字体夹具和具体图像已获批准后更新；本轮37张已分两批获批，不意味着以后可以自动整目录update。以下普通比较在授权Linux测试机执行，本机不恢复工具链：

```bash
python3 tool/prepare_golden_font.py --output "$PWD/.dart_tool/golden-font/NotoSansCJK-Regular.ttc"
export XB_GOLDEN_CJK_FONT="$PWD/.dart_tool/golden-font/NotoSansCJK-Regular.ttc"
python3 tool/flutter_check.py --no-pub --concurrency=1 test/xboard/golden
```

只维护桌面外壳时限定范围，审阅 PNG 后再进行第二条不更新基线的检查：

```bash
flutter test --no-pub --update-goldens test/xboard/golden/desktop_shell_golden_test.dart
flutter test --no-pub test/xboard/golden/desktop_shell_golden_test.dart
```

## 看不懂某个 golden 失败？

1. 失败图落在 `test/xboard/golden/failures/`（`*_testImage.png` 本次渲染 / `*_masterImage.png`
   基线 / `*_maskedDiff.png` 差异）。先对比看是「真实 UI 变化」还是「渲染漂移」。
2. **真实 UI 变了**（改了页面）→ 核对变更是否符合已确认需求；先修不期望的变化，审阅后再生成基线。
3. **渲染漂移**（环境不符）→ 别先重生成；核对该批次工具链、字体摘要和加载策略，不把历史环境声明误当当前CI事实。
4. 结构类断言（`find...` / 无溢出 / 对比度）失败 ≠ 像素失配：
    - `find.text` 默认**不匹配 RichText**（`EmojiText` 即 RichText）→ 用 `find.text(s, findRichText: true)`。
    - Flutter内建 `textContrastGuideline` 不覆盖任意RichText作者内联颜色；通过不等于全部HTML满足AA。套餐测试另遍历真实渲染span，针对无内联背景的固定夹具检查4.5门槛；嵌套背景/RGBA/继承/链接由`xb_html_contrast_test.dart`覆盖，不以像素基线批准替代修复。

## 历史

- 2026-06-27：全量基线在规范环境（Linux / Flutter 3.44.0 / Noto CJK）重生成，修复跨环境像素漂移；
  CI 锁 Flutter 版本 + 装 fonts-noto-cjk 确定化；新增本说明。
- 2026-10-13：桌面复查发现原基线仍包含方块文字，且固定套餐日期已到期；
  修正截图字体、稳定套餐夹具，审阅并更新8张桌面基线，其他基线保持原状。

- 2026-10-18：导航栏固定盾牌改为资产图片，补图片解码等待并更新8张桌面基线；与原图差异仅在左上角40×40区域。
