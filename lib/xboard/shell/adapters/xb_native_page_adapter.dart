/// 形态 A 原生页适配器（spec `xboard-form-a-ui-revamp` / W2.5 / R6.8）。
///
/// **职责（风险②b 收口）**：把「从自定义壳 push FlClash 原生页」收口。形态 A「我的 → 设置」
/// 用形态 A 风格的设置列表页（`XbSettingsPage`，组件库样式），其各条目 push 进 FlClash
/// 原生子页（主题 / 备份 / 访问控制 / 配置 / 应用设置 / 关于 等）—— 深层编辑页保留 FlClash
/// 原貌（复杂原生屏，加而不改），只有设置「列表」本身按原型重做。
///
/// Tab / 设置页不直接 import `lib/views/**`，全部经本适配器收口（适配层铁律）。本文件是
/// 唯一允许 import `package:fl_clash/views/**` 的收口点。
library;

import 'package:fl_clash/common/common.dart' show system;
import 'package:fl_clash/l10n/l10n.dart' show AppLocalizations;
import 'package:fl_clash/providers/config.dart' show appSettingProvider;
import 'package:fl_clash/state.dart' show globalState;
import 'package:fl_clash/views/about.dart' show AboutView;
import 'package:fl_clash/views/access.dart' show AccessView;
import 'package:fl_clash/views/application_setting.dart'
    show ApplicationSettingView;
import 'package:fl_clash/views/backup_and_restore.dart' show BackupAndRestore;
import 'package:fl_clash/views/config/advanced.dart' show AdvancedConfigView;
import 'package:fl_clash/views/config/config.dart' show ConfigView;
import 'package:fl_clash/views/connection/connections.dart'
    show ConnectionsView;
import 'package:fl_clash/views/connection/requests.dart' show RequestsView;
import 'package:fl_clash/views/resources.dart' show ResourcesView;
import 'package:fl_clash/views/theme.dart' show ThemeView;
import 'package:fl_clash/views/tools.dart' show ToolsView;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 原生页适配器。
class XbNativePageAdapter {
  const XbNativePageAdapter();

  /// 兜底：直接 push 整张 FlClash 原生 ToolsView（保留入口，防 formA 设置页异常时可用）。
  Future<void> openNativeTools(BuildContext context) =>
      _push(context, const ToolsView());

  // —— 各 FlClash 原生子页 push（唯一允许 import lib/views/** 的收口点）——

  Future<void> openTheme(BuildContext context) =>
      _push(context, const ThemeView());

  Future<void> openBackup(BuildContext context) =>
      _push(context, const BackupAndRestore());

  Future<void> openAccessControl(BuildContext context) =>
      _push(context, const AccessView());

  Future<void> openBasicConfig(BuildContext context) =>
      _push(context, const ConfigView());

  Future<void> openAdvancedConfig(BuildContext context) =>
      _push(context, const AdvancedConfigView());

  Future<void> openApplicationSetting(BuildContext context) =>
      _push(context, const ApplicationSettingView());

  /// FlClash 原生「请求」页（流量请求列表）。
  Future<void> openRequests(BuildContext context) =>
      _push(context, const RequestsView());

  /// FlClash 原生「连接」页（活动连接列表）。
  Future<void> openConnections(BuildContext context) =>
      _push(context, const ConnectionsView());

  /// FlClash 原生「资源」页（GEOIP / GEOSITE / MMDB / ASN 等数据文件）。
  Future<void> openResources(BuildContext context) =>
      _push(context, const ResourcesView());

  Future<void> openAbout(BuildContext context) =>
      _push(context, const AboutView());

  /// 语言选择（FlClash appSettingProvider.locale）。formA 风格底部选择器。
  /// 仅本适配器触碰 FlClash 设置 provider（适配层铁律）。
  Future<void> pickLocale(BuildContext context, WidgetRef ref) async {
    final supported = AppLocalizations.delegate.supportedLocales;
    final options = <Locale?>[null, ...supported];
    final current = ref.read(appSettingProvider).locale;
    String labelOf(Locale? l) => l == null
        ? '跟随系统'
        : switch (l.toString()) {
            'zh_CN' => '简体中文',
            'en' => 'English',
            'ja' => '日本語',
            'ru' => 'Русский',
            _ => l.toString(),
          };
    final picked = await showModalBottomSheet<Object?>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in options)
              ListTile(
                title: Text(labelOf(l)),
                trailing: (l?.toString() ?? '') == (current ?? '')
                    ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(l ?? 'null'),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return; // 关闭未选
    final locale = picked == 'null' ? null : picked as Locale;
    ref
        .read(appSettingProvider.notifier)
        .update((s) => s.copyWith(locale: locale?.toString()));
  }

  /// 当前界面语言展示文案。
  String localeLabel(WidgetRef ref) {
    final l = ref.read(appSettingProvider).locale;
    return switch (l) {
      null => '跟随系统',
      'zh_CN' => '简体中文',
      'en' => 'English',
      'ja' => '日本語',
      'ru' => 'Русский',
      _ => l,
    };
  }

  /// 免责声明（FlClash globalState 流程：拒绝则退出 App，由调用方处理）。
  Future<bool> showDisclaimer() => globalState.showDisclaimer();

  /// 当前平台是否 Android（访问控制仅 Android）。
  bool get isAndroid => system.isAndroid;

  Future<void> _push(BuildContext context, Widget page) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

/// 原生页适配器单例 provider（Tab / 设置页经此取，测试可 override）。
final xbNativePageAdapterProvider = Provider<XbNativePageAdapter>(
  (ref) => const XbNativePageAdapter(),
);
