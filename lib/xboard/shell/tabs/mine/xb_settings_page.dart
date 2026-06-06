/// 形态 A 设置页（spec `xboard-form-a-ui-revamp` / R6.8）。
///
/// **复用 FlClash ToolsView 全部选项 + 原型风格**：列表本身用组件库（XbListCard/XbGroupLabel）
/// 按原型 `settings()` 分「设置 / 其他」两组重做；各条目 push 进 FlClash 原生子页（深层编辑屏
/// 保留原貌，加而不改）。原生子页一律经 `XbNativePageAdapter` 收口（适配层铁律）。
///
/// 分组（对齐原型 settings()）：
///   设置：语言 / 主题 / 备份与恢复 / 访问控制(仅 Android) / 基础配置 / 高级配置 / 应用设置
///   其他：免责声明 / 关于
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

import '../../adapters/xb_native_page_adapter.dart';

/// 形态 A 设置页。
class XbSettingsPage extends ConsumerWidget {
  const XbSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 设置页经 Navigator push（挂根 Navigator），自套品牌主题避免逃逸。
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(builder: (context) => _buildScaffold(context, ref)),
    );
  }

  Widget _buildScaffold(BuildContext context, WidgetRef ref) {
    final adapter = ref.read(xbNativePageAdapterProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // ── 设置组 ──
          const XbGroupLabel('设置'),
          XbListCard(
            rows: [
              XbListRow(
                icon: Icons.language,
                label: '语言',
                subtitle: '界面显示语言',
                badge: adapter.localeLabel(ref),
                showChevron: false,
                onTap: () => adapter.pickLocale(context, ref),
              ),
              XbListRow(
                icon: Icons.palette_outlined,
                label: '主题',
                subtitle: '深浅色 / 主题色 / 字号',
                onTap: () => adapter.openTheme(context),
              ),
              XbListRow(
                icon: Icons.cloud_sync_outlined,
                label: '备份与恢复',
                subtitle: '导出 / 导入应用数据',
                onTap: () => adapter.openBackup(context),
              ),
              if (adapter.isAndroid)
                XbListRow(
                  icon: Icons.apps,
                  label: '访问控制',
                  subtitle: '按应用分流（仅 Android）',
                  onTap: () => adapter.openAccessControl(context),
                ),
              XbListRow(
                icon: Icons.tune,
                label: '基础配置',
                subtitle: 'TUN / 端口 / DNS / 局域网 等',
                onTap: () => adapter.openBasicConfig(context),
              ),
              XbListRow(
                icon: Icons.build_outlined,
                label: '高级配置',
                subtitle: '内核高级参数',
                onTap: () => adapter.openAdvancedConfig(context),
              ),
              XbListRow(
                icon: Icons.settings_applications_outlined,
                label: '应用设置',
                subtitle: '开机自启 / 托盘 / 日志 / 更新 等',
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
                onTap: () => adapter.showDisclaimer(),
              ),
              XbListRow(
                icon: Icons.info_outline,
                label: '关于',
                badge: kBuildTag.isEmpty ? null : kBuildTag,
                onTap: () => adapter.openAbout(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
