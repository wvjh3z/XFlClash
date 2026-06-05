/// 形态 A 设计语言**单一真源**（spec `xboard-form-a-ui-revamp` / 原型 full.html CSS token）。
///
/// **设计意图**：把原型的全部设计 token（颜色 / 圆角 / 阴影 / 间距）和**组件子主题**
/// （按钮 / 卡片 / 输入框 / sheet / appbar …）集中在这一个文件里。全 App 经
/// [buildXbTheme] 注入这份 ThemeData，各页面/widget **直接吃主题默认值**，不再手写
/// 圆角/颜色/阴影 —— 改设计只动这一处。
///
/// **作用域**：shell body + sheet 入口 + 页面 push 入口三处统一套 [XbBrandTheme]
/// （内部调本文件），堵住「sheet/页面挂根 Navigator 拿不到主题」的漏洞。
library;

import 'package:flutter/material.dart';

/// 原型设计 token（full.html `:root` 浅色 / `.screen.dark` 深色）。
///
/// 硬钉值（不走 M3 算法），保证中性底是干净灰、不泛品牌色相；圆角/阴影/间距全部对齐原型。
class XbTokens {
  const XbTokens({
    required this.sf,
    required this.sf2,
    required this.card,
    required this.sfc,
    required this.on,
    required this.onv,
    required this.line,
    required this.hair,
    required this.shadow1,
    required this.shadow2,
  });

  // —— 颜色（中性底色族，原型 CSS 变量）——
  final Color sf; // --sf 页面背景
  final Color sf2; // --sf2 纯白面（sheet / orb 核心）
  final Color card; // --card 卡片
  final Color sfc; // --sfc 容器 / 分段槽 / 输入框填充
  final Color on; // --on 正文
  final Color onv; // --onv 次要文字
  final Color line; // --line 边框
  final Color hair; // --hair 细分隔线
  // —— 阴影（--sd1 普通卡 / --sd2 强调卡）——
  final List<BoxShadow> shadow1;
  final List<BoxShadow> shadow2;

  // —— 语义状态色（原型 --ok / --warn / --bad / --info / --conn）——
  // 浅深通用（原型深色未单独覆盖语义色），统一定义于此。
  static const Color ok = Color(0xFF16A34A); // 成功 / 已完成 / 已连接同族
  static const Color warn = Color(0xFFE08A1E); // 告警 / 流量将尽 / 待支付
  static const Color bad = Color(0xFFDC3B2C); // 错误 / 已取消 / 高延迟
  static const Color info = Color(0xFF2563EB); // 信息
  static const Color conn = Color(0xFF10B981); // 已连接绿（连接球语义，备用）

  // —— 圆角（--rb / --rc + 组件专用）——
  static const double rButton = 16; // .cta
  static const double rField = 15; // .field / .go
  static const double rCard = 24; // --rc / .card
  static const double rCardSmall = 17; // .metric
  static const double rChip = 11; // .loginbar .lb / .modeseg .s
  static const double rSheet = 30; // .sheet 顶圆角
  static const double rPill = 12; // .guestlogin

  // —— 尺寸 ——
  static const double hButton = 54; // .go / .b
  static const double hCta = 56; // .cta

  static const light = XbTokens(
    sf: Color(0xFFF5F6F8),
    sf2: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    sfc: Color(0xFFEEF0F4),
    on: Color(0xFF11141B),
    onv: Color(0xFF6A7180),
    line: Color(0xFFE9ECF1),
    hair: Color(0xFFF0F2F5),
    shadow1: [
      BoxShadow(
          color: Color(0x0A0F172A), blurRadius: 16, offset: Offset(0, 6), spreadRadius: -8),
    ],
    shadow2: [
      BoxShadow(
          color: Color(0x290F172A), blurRadius: 36, offset: Offset(0, 16), spreadRadius: -14),
    ],
  );

  static const dark = XbTokens(
    sf: Color(0xFF0A0C11),
    sf2: Color(0xFF13161D),
    card: Color(0xFF13161D),
    sfc: Color(0xFF171A22),
    on: Color(0xFFF1F3F8),
    onv: Color(0xFF8990A2),
    line: Color(0xFF23262F),
    hair: Color(0xFF1A1D25),
    shadow1: [
      BoxShadow(
          color: Color(0x80000000), blurRadius: 20, offset: Offset(0, 8), spreadRadius: -10),
    ],
    shadow2: [
      BoxShadow(
          color: Color(0x99000000), blurRadius: 40, offset: Offset(0, 18), spreadRadius: -14),
    ],
  );

  /// 从当前主题取 token（[buildXbTheme] 注入到 ThemeExtension）。
  static XbTokens of(BuildContext context) =>
      Theme.of(context).extension<_XbTokensExt>()?.tokens ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);
}

/// 把 [XbTokens] 挂到 ThemeData.extensions，供定制 widget（连接球/账号卡/徽标）读取。
class _XbTokensExt extends ThemeExtension<_XbTokensExt> {
  const _XbTokensExt(this.tokens);
  final XbTokens tokens;

  @override
  ThemeExtension<_XbTokensExt> copyWith({XbTokens? tokens}) =>
      _XbTokensExt(tokens ?? this.tokens);

  @override
  ThemeExtension<_XbTokensExt> lerp(ThemeExtension<_XbTokensExt>? other, double t) =>
      this; // 离散 token，不插值
}

/// 构建形态 A 完整 ThemeData：品牌色强调 + 原型中性底 + **全组件子主题**。
///
/// 调用方（[XbBrandTheme]）只管传 brandColor + brightness。各 widget 直接用主题默认值：
/// `FilledButton`/`OutlinedButton`/`Card`/`TextField`/`bottomSheet`/`AppBar`/`Divider`/
/// `progressIndicator`/`ListTile` 全部已配齐，无需再 styleFrom。
ThemeData buildXbTheme({required Color brandColor, required Brightness brightness}) {
  final isLight = brightness == Brightness.light;
  final t = isLight ? XbTokens.light : XbTokens.dark;

  // 品牌强调色族（fidelity）：用于 secondary/tertiary/error 的协调色；primary 锁品牌本色。
  final brand = ColorScheme.fromSeed(
    seedColor: brandColor,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );

  final scheme = brand.copyWith(
    primary: brandColor,
    onPrimary: Colors.white,
    surface: t.sf,
    onSurface: t.on,
    onSurfaceVariant: t.onv,
    surfaceContainerLowest: t.card,
    surfaceContainerLow: t.card,
    surfaceContainer: t.sfc,
    surfaceContainerHigh: t.sfc,
    surfaceContainerHighest: t.sfc,
    outline: t.line,
    outlineVariant: t.line,
    inverseSurface: t.on,
    onInverseSurface: t.sf,
    // 🔴 全局根治「背景泛粉红」：M3 按 elevation 给所有 Material/Card/Sheet/Dialog/AppBar
    // 叠一层 surfaceTint(=primary 品牌红)。设透明 → 全 App 任何 elevation 都不再叠色染红。
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme);

  OutlinedBorder rrect(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  InputBorder fieldBorder(Color c, [double w = 1.0]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(XbTokens.rField),
        borderSide: w == 0 ? BorderSide.none : BorderSide(color: c, width: w),
      );

  // 集中排版（原型字号/字重映射 M3 TextTheme）：页面/组件用 textTheme.* 取，不再手写魔法字号。
  final textTheme = base.textTheme.apply(
    bodyColor: t.on,
    displayColor: t.on,
  ).copyWith(
    headlineSmall: TextStyle(
        fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: t.on),
    titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: t.on),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.on),
    titleSmall: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: t.on),
    bodyMedium: TextStyle(fontSize: 14, color: t.on),
    bodySmall: TextStyle(fontSize: 12.5, color: t.onv),
    labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.on),
    labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.onv),
  );

  return base.copyWith(
    scaffoldBackgroundColor: t.sf,
    extensions: [_XbTokensExt(t)],
    textTheme: textTheme,

    // 主按钮（.cta / .go）：品牌红实心 + 圆角16 + 高52 + 粗字。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brandColor,
        foregroundColor: Colors.white,
        // 最小宽 0（按内容撑宽，全宽场景调用方用 Expanded/SizedBox 包；
        // 不用 Size.fromHeight 以免最小宽=∞ 在无界 Row 里崩）。
        minimumSize: const Size(0, XbTokens.hButton),
        shape: rrect(XbTokens.rButton),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
        elevation: 0,
      ),
    ),
    // 次按钮（.b.ghost / .cta.out）：品牌描边。
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: brandColor,
        minimumSize: const Size(0, XbTokens.hButton),
        side: BorderSide(color: brandColor.withValues(alpha: 0.40), width: 1.6),
        shape: rrect(XbTokens.rButton),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    // 链接/文字按钮（.alt b）：品牌色粗字。
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brandColor,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    // 卡片（.card）：白底 + 圆角24 + sd1 阴影（用 surfaceTint 关掉 M3 染色）。
    cardTheme: CardThemeData(
      color: t.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XbTokens.rCard),
        side: BorderSide(color: t.line),
      ),
    ),
    // 输入框（.field）：填充 sfc + 圆角15 + 无边框 + 聚焦品牌边。
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.sfc,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: TextStyle(color: t.onv),
      floatingLabelStyle: TextStyle(color: brandColor),
      hintStyle: TextStyle(color: t.onv),
      prefixIconColor: t.onv,
      border: fieldBorder(t.line, 0),
      enabledBorder: fieldBorder(t.line, 0),
      focusedBorder: fieldBorder(brandColor, 1.8),
      errorBorder: fieldBorder(scheme.error, 1.4),
      focusedErrorBorder: fieldBorder(scheme.error, 1.8),
    ),
    // 底部 sheet（.sheet）：白面 + 顶圆角30。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.sf2,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: t.sf2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(XbTokens.rSheet)),
      ),
      showDragHandle: true,
      dragHandleColor: t.line,
    ),
    // AppBar（.abar）：贴页面底色 + 无阴影 + 大标题左对齐。
    appBarTheme: AppBarTheme(
      backgroundColor: t.sf,
      surfaceTintColor: Colors.transparent,
      foregroundColor: t.on,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
          color: t.on, fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3),
    ),
    // 对话框（.dialog）：白面 + 圆角 + 不叠色。
    dialogTheme: DialogThemeData(
      backgroundColor: t.sf2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: rrect(20),
      titleTextStyle: TextStyle(
          color: t.on, fontSize: 18, fontWeight: FontWeight.w700),
      contentTextStyle: TextStyle(color: t.onv, fontSize: 14, height: 1.5),
    ),
    dividerTheme: DividerThemeData(color: t.hair, thickness: 1, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: brandColor,
      linearTrackColor: t.sfc,
      circularTrackColor: Colors.transparent,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.onv,
      textColor: t.on,
      titleTextStyle: TextStyle(color: t.on, fontSize: 15),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: t.sfc,
      side: BorderSide.none,
      shape: rrect(XbTokens.rChip),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      shape: rrect(12),
    ),
  );
}

/// 形态 A 页面 push helper —— 自动用品牌主题包裹被推入的页面。
///
/// 页面挂根 Navigator（FlClash MaterialApp 下），不在 shell 子树内 → 不包则拿不到品牌主题。
/// 用法：`xbPush(context, const PlanListPage())` 代替手写 `Navigator.push(MaterialPageRoute(...))`。
Future<T?> xbPush<T>(
  BuildContext context,
  Widget page, {
  required Color brandColor,
  bool replace = false,
}) {
  final route = MaterialPageRoute<T>(
    builder: (_) => _XbBrandThemeHost(brandColor: brandColor, child: page),
  );
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}

/// 内部：给 push 的页面套品牌主题（避免 xb_theme 依赖 xb_ui_kit，防循环 import）。
class _XbBrandThemeHost extends StatelessWidget {
  const _XbBrandThemeHost({required this.brandColor, required this.child});
  final Color brandColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildXbTheme(
        brandColor: brandColor,
        brightness: Theme.of(context).brightness,
      ),
      child: child,
    );
  }
}

/// 形态 A 对话框 helper —— 自动用品牌主题包裹（dialog 挂根 Navigator，同样会逃逸主题）。
///
/// 用法：`xbShowDialog(context: context, brandColor: ..., builder: ...)` 代替裸 `showDialog`。
Future<T?> xbShowDialog<T>({
  required BuildContext context,
  required Color brandColor,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => _XbBrandThemeHost(
      brandColor: brandColor,
      child: Builder(builder: builder),
    ),
  );
}
