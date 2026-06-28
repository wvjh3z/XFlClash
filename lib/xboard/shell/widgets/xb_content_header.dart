/// 形态 A 桌面内容区固定标题栏（原型 `.chd`）。
///
/// C-分支桌面外壳：每个 Tab 内容区顶部一条固定 58px 标题条（标题左 + 操作右），
/// 底部一条 hairline 分隔线，与下方可滚动内容区分隔。标题**不随内容滚动**。
/// 移动端不用此组件（标题在滚动体内，无分隔线）。
library;

import 'package:flutter/material.dart';

import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;

/// 桌面内容区固定标题栏。
class XbContentHeader extends StatelessWidget {
  const XbContentHeader({
    super.key,
    required this.title,
    this.titleTrailing,
    this.trailing,
    this.maxContentWidth,
  });

  /// 左侧标题（如「首页」/「选择线路」/「我的」）。
  final String title;

  /// 标题**右侧紧邻**的小部件（如首页「有新公告」胶囊）；null = 无。
  final Widget? titleTrailing;

  /// 右侧操作区（更新胶囊 / 刷新按钮等）；null = 无操作。
  final Widget? trailing;

  /// 内容最大宽度（与下方内容区同值时，标题右侧操作与内容右缘对齐）。
  /// null = 内容铺满标题栏（减去左右 28 padding）。
  final double? maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: t.on,
            ),
          ),
          if (titleTrailing != null) ...[
            const SizedBox(width: 10),
            titleTrailing!,
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
    if (maxContentWidth != null) {
      // 居中限宽，使标题/操作右缘与下方内容区（同 maxContentWidth）严格对齐。
      row = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxContentWidth!),
          child: row,
        ),
      );
    }
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: t.sf,
        border: Border(bottom: BorderSide(color: t.hair)),
      ),
      child: row,
    );
  }
}
