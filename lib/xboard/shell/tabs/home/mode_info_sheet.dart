/// 形态 A 代理模式说明 sheet（spec `xboard-form-a-ui-revamp` / W3.5 / R3.3·R3.4·R3.5）。
///
/// 模式标题右侧 ⓘ 点击 → 底部 sheet：智能模式（国内直连 / 海外走 VPN，R3.4）+
/// 全局模式（全走 VPN、国内 App 绕经海外体验差非必要不用，R3.5）。
///
/// **共用组件**：标题居中 + modeexp 解释卡 + 品牌「知道了」全部由 [XbInfoSheet] 统一表达
/// （与线路分组类型说明同源，改一处全改）。纯 UI，无 provider 依赖。
library;

import 'package:flutter/material.dart';

import '../../../widgets/xb_components.dart' show XbInfoSheet, XbInfoItem;
import '../../sheets/sheet_scaffold.dart' show showXbBottomSheet;

/// 弹出模式说明底部 sheet（走统一入口 showXbBottomSheet：自动套品牌主题 + 白底，不逃逸主题）。
Future<void> showModeInfoSheet(BuildContext context) {
  return showXbBottomSheet<void>(
    context: context,
    builder: (context) => const XbInfoSheet(
      title: '代理模式说明',
      subtitle: '两种模式按需切换',
      headerIcon: Icons.help_outline,
      items: [
        XbInfoItem(
          icon: Icons.bolt,
          title: '智能模式',
          desc: '国内网站与 App 直连、不绕路，访问更快更省流量；海外网站与 App 自动走 VPN 加密。'
              '绝大多数人用这个就好。',
        ),
        XbInfoItem(
          icon: Icons.public,
          title: '全局模式',
          desc: '所有流量（含国内）都走 VPN 加密。国内访问会因此绕远、变慢，'
              '仅在需要全程加密或排查网络问题时临时开启。',
        ),
      ],
    ),
  );
}
