/// 形态 A 设置页（spec `xboard-form-a-ui-revamp` / R6.8）。
///
/// **复用 FlClash ToolsView 全部选项 + 原型风格**：列表本身用组件库（XbListCard/XbGroupLabel）
/// 按原型 `settings()` 分「设置 / 其他」两组重做；各条目 push 进 FlClash 原生子页（深层编辑屏
/// 保留原貌，加而不改）。原生子页一律经 `XbNativePageAdapter` 收口（适配层铁律）。
///
/// 分组（对齐原型 settings()）：
///   设置：语言 / 主题 / 备份与恢复 / 访问控制(仅 Android) / 基础配置 / 高级配置 / 应用设置
///   数据与诊断：请求 / 连接 / 资源（复用 FlClash 工具页 RequestsView/ConnectionsView/ResourcesView）
///   其他：免责声明 / 关于
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandScaffold;

import '../../adapters/xb_native_page_adapter.dart';
import '../../widgets/xb_content_header.dart';

/// 语言设置入口可见性开关（用户 2026-06-20：默认强制简体中文，隐藏语言切换入口）。
/// **隐藏而非删除**——代码保留，将来若要恢复多语言，置 true 即可（并取消 bootstrap 的强制 locale）。
const bool _kShowLanguageSetting = false;

/// 形态 A 设置页。
class XbSettingsPage extends ConsumerWidget {
  const XbSettingsPage({super.key, this.embedded = false});

  /// 桌面「内容区 Tab」嵌入态（C-分支）：去掉 Scaffold/AppBar，改用固定标题栏
  /// [XbContentHeader]（与首页/节点/我的 Tab 一致），由 NavRail 宿主提供窗口 chrome。
  /// 默认 false = 移动端经 Navigator push 的整屏页（XbBrandScaffold + AppBar，不变）。
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (embedded) {
      // 桌面 NavRail 第 4 Tab：固定标题栏 + 可滚动设置列表（不再嵌原生 ToolsView，
      // 直接复用本页 = 与「我的」Tab 设置入口同一份内容，避免重复 + 规避原生页崩溃）。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const XbContentHeader(title: '设置'),
          Expanded(child: _buildBody(context, ref)),
        ],
      );
    }
    // 设置页经 Navigator push（挂根 Navigator），XbBrandScaffold 自套品牌主题避免逃逸。
    return XbBrandScaffold(
      title: '设置',
      body: _buildBody(context, ref),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final adapter = ref.read(xbNativePageAdapterProvider);
    // 桌面（宽≥600，含内容区嵌入态）行放大，与「我的」菜单一致；移动端紧凑。
    final large = MediaQuery.sizeOf(context).width >= 600;
    return Center(
      child: ConstrainedBox(
        // 原型屏8 `.setlist{max-width:720px;margin:0 auto}`。
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // ── 更多组（PC 端独立的 请求/连接/资源 整合进顶部「更多」，原型屏8）──
            const XbGroupLabel('更多'),
            XbListCard(
              rows: [
                XbListRow(
                  icon: Icons.view_timeline_outlined,
                  label: '请求',
                  subtitle: '查看最近请求记录',
                  large: large,
                  onTap: () => adapter.openRequests(context),
                ),
                XbListRow(
                  icon: Icons.ballot_outlined,
                  label: '连接',
                  subtitle: '查看当前连接数据',
                  large: large,
                  onTap: () => adapter.openConnections(context),
                ),
                XbListRow(
                  icon: Icons.storage_outlined,
                  label: '资源',
                  subtitle: '外部资源相关信息',
                  large: large,
                  onTap: () => adapter.openResources(context),
                ),
              ],
            ),
            // ── 设置组 ──
            const XbGroupLabel('设置'),
            XbListCard(
              rows: [
                // 语言入口：默认隐藏（强制简体中文）。隐藏而非删除，置 _kShowLanguageSetting=true 可恢复。
                if (_kShowLanguageSetting)
                  XbListRow(
                    icon: Icons.language,
                    label: '语言',
                    subtitle: '界面显示语言',
                    large: large,
                    badge: adapter.localeLabel(ref),
                    showChevron: false,
                    onTap: () => adapter.pickLocale(context, ref),
                  ),
                XbListRow(
                  icon: Icons.palette_outlined,
                  label: '主题',
                  subtitle: '设置深色模式，调整色彩',
                  large: large,
                  onTap: () => adapter.openTheme(context),
                ),
                XbListRow(
                  icon: Icons.cloud_sync_outlined,
                  label: '备份与恢复',
                  subtitle: '通过 WebDAV 或文件同步数据',
                  large: large,
                  onTap: () => adapter.openBackup(context),
                ),
                if (adapter.isAndroid)
                  XbListRow(
                    icon: Icons.apps,
                    label: '访问控制',
                    subtitle: '按应用分流（仅 Android）',
                    large: large,
                    onTap: () => adapter.openAccessControl(context),
                  ),
                XbListRow(
                  icon: Icons.edit_outlined,
                  label: '基本配置',
                  subtitle: '全局修改基本配置',
                  large: large,
                  onTap: () => adapter.openBasicConfig(context),
                ),
                XbListRow(
                  icon: Icons.build_outlined,
                  label: '进阶配置',
                  subtitle: '提供多样化配置',
                  large: large,
                  onTap: () => adapter.openAdvancedConfig(context),
                ),
                XbListRow(
                  icon: Icons.settings_applications_outlined,
                  label: '应用程序',
                  subtitle: '修改应用程序相关设置',
                  large: large,
                  onTap: () => adapter.openApplicationSetting(context),
                ),
              ],
            ),
            // ── 其他组 ──
            const XbGroupLabel('其他'),
            XbListCard(
              rows: [
                XbListRow(
                  icon: Icons.gavel,
                  label: '免责声明',
                  large: large,
                  onTap: () => adapter.showDisclaimer(),
                ),
                XbListRow(
                  icon: Icons.info_outline,
                  label: '关于',
                  large: large,
                  onTap: () => adapter.openAbout(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
