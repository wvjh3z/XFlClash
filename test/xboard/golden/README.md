# Golden 测试 — 规范环境与重生成

形态 A 页面/外壳的 golden 截图测试（首页/节点/我的/套餐/订单/更新弹窗/桌面外壳/a11y）。
用注入数据渲染 → 像素比对，跟原型对齐。不依赖模拟器，可重复、可进 CI。

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

## 重生成基线

只在规范环境跑（否则会把本机的渲染差异写进基线、害别处失配）：

```bash
flutter test --update-goldens test/xboard/golden
# 重生成后必须不带 --update 再跑一遍确认稳定通过：
flutter test test/xboard/golden
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
