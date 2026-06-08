/// 形态 A 出口 IP 卡（spec `xboard-form-a-ui-revamp` / W3 · 原型 `.ipcard`）。
///
/// 借用 FlClash `networkDetection`（多源竞速检测出口 IP，经 [XbNetworkAdapter] 收口）。
/// 与登录无关：游客 / 未连接也显示本地直连出口 IP；已连接显示 VPN 出口 IP；检测中显示转圈。
/// 标签格式「出口 IP (国家)」。点右侧刷新重新检测。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbIconBadge;

import '../../adapters/xb_network_adapter.dart';

/// 出口 IP 卡。
class XbIpCard extends ConsumerWidget {
  const XbIpCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final adapter = ref.watch(xbNetworkAdapterProvider);
    final status = adapter.ipStatus(ref);

    final flag = status.hasIp
        ? _countryCodeToEmoji(status.countryCode)
        : null;
    final country = _countryName(status.countryCode);
    final label = '出口 IP${country != null ? ' ($country)' : ''}';
    final String value;
    if (status.loading && !status.hasIp) {
      value = '检测中…';
    } else if (status.hasIp) {
      value = status.ip!;
    } else {
      value = '检测失败';
    }

    return Container(
      margin: const EdgeInsets.only(top: 11),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: Border.all(color: t.line),
        boxShadow: t.shadow1,
      ),
      child: Row(
        children: [
          // 国旗块（有 IP 显示国旗 emoji，否则通用网络图标）。
          flag != null
              ? Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.sfc,
                    borderRadius: BorderRadius.circular(XbTokens.rSm),
                  ),
                  child: Text(flag, style: const TextStyle(fontSize: 19)),
                )
              : XbIconBadge(
                  icon: Icons.public,
                  size: 34,
                  radius: XbTokens.rSm,
                  background: t.sfc,
                  iconColor: t.onv,
                  iconSize: 19,
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(fontSize: 11.5, color: t.onv)),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: t.on,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 刷新（检测中显示转圈）。
          IconButton(
            onPressed: status.loading ? null : () => adapter.forceCheck(ref),
            visualDensity: VisualDensity.compact,
            icon: status.loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: scheme.primary),
                  )
                : Icon(Icons.refresh, size: 20, color: scheme.primary),
          ),
        ],
      ),
    );
  }

  /// 国家码 → 国旗 emoji（同 FlClash network_detection 实现）。
  String? _countryCodeToEmoji(String? code) {
    if (code == null || code.length != 2) return null;
    final c = code.toUpperCase();
    final first = c.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = c.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(first) + String.fromCharCode(second);
  }

  /// 国家码 → 中文名（常见地区，其余回退国家码本身）。
  String? _countryName(String? code) {
    if (code == null || code.isEmpty) return null;
    const names = {
      'HK': '香港', 'TW': '台湾', 'MO': '澳门', 'CN': '中国',
      'JP': '日本', 'SG': '新加坡', 'KR': '韩国', 'US': '美国',
      'GB': '英国', 'DE': '德国', 'FR': '法国', 'NL': '荷兰',
      'CH': '瑞士', 'ES': '西班牙', 'CA': '加拿大', 'AU': '澳大利亚',
      'IN': '印度', 'VN': '越南', 'TH': '泰国', 'MY': '马来西亚',
      'RU': '俄罗斯', 'TR': '土耳其', 'AE': '迪拜', 'PH': '菲律宾',
    };
    return names[code.toUpperCase()] ?? code.toUpperCase();
  }
}
