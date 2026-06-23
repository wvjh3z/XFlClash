/// 形态 A「网络接管方式」说明 sheet（桌面专属，spec `xboard-form-a-ui-revamp`）。
///
/// 首页右栏「网络接管方式」卡标题右侧 ⓘ 点击 → 说明弹窗：系统代理 + 虚拟网卡(TUN)。
/// 两者互不互斥、可同时开启、互补接管流量（与上游 FlClash 一致）。
///
/// **共用组件**：复用 [XbInfoSheet]（与代理模式 / 分组类型说明同源，改一处全改）。纯 UI。
library;

import 'package:flutter/material.dart';

import '../../../widgets/xb_components.dart' show XbInfoSheet, XbInfoItem;
import '../../sheets/sheet_scaffold.dart' show showXbInfoPopup;

/// 弹出网络接管方式说明弹窗（响应式：桌面居中对话框 / 移动底部 sheet；自动套品牌主题）。
Future<void> showTakeoverInfoSheet(BuildContext context) {
  return showXbInfoPopup<void>(
    context: context,
    builder: (context) => const XbInfoSheet(
      title: '网络接管方式说明',
      subtitle: '两种方式可同时开启，互补接管流量',
      items: [
        XbInfoItem(
          icon: Icons.shuffle,
          title: '系统代理',
          desc: '为操作系统设置代理。浏览器等「遵循系统代理」的应用会走加密；'
              '不遵循代理的应用不受影响。无需管理员权限。日常推荐。',
        ),
        XbInfoItem(
          icon: Icons.lan,
          title: '虚拟网卡 (TUN)',
          desc: '创建虚拟网卡，在系统底层接管全部流量，兜底那些不遵循代理设置的应用。'
              '需要管理员 / Root 权限。',
        ),
      ],
    ),
  );
}
