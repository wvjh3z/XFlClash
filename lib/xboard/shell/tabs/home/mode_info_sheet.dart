/// 形态 A 代理模式说明 sheet（spec `xboard-form-a-ui-revamp` / W3.5 / R3.3·R3.4·R3.5）。
///
/// 模式标题右侧 ⓘ 点击 → 底部 sheet：智能模式（国内直连 / 海外走 VPN，R3.4）+
/// 全局模式（全走 VPN、国内 App 绕经海外体验差非必要不用，R3.5）。
///
/// 纯 UI，无 provider 依赖。
library;

import 'package:flutter/material.dart';

/// 弹出模式说明底部 sheet。
Future<void> showModeInfoSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => const _ModeInfoSheet(),
  );
}

class _ModeInfoSheet extends StatelessWidget {
  const _ModeInfoSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text(
              '代理模式说明',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(
              '两种模式按需切换',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            _ModeExplain(
              icon: Icons.bolt,
              title: '智能模式',
              desc: '自动识别流量去向：国内 App 与网站走直连、不经过 VPN，访问更快更省流量；'
                  '海外 App 与网站自动通过 VPN 加密访问。日常推荐。',
              scheme: scheme,
            ),
            const SizedBox(height: 12),
            _ModeExplain(
              icon: Icons.public,
              title: '全局模式',
              desc: '所有流量都通过 VPN 加密传输，包括国内访问。该模式下中国 App 的流量也会'
                  '绕经海外，网络体验较差、延迟更高，非必要不建议使用。适合需要全程加密或'
                  '排查网络问题时临时开启。',
              scheme: scheme,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _ModeExplain extends StatelessWidget {
  const _ModeExplain({
    required this.icon,
    required this.title,
    required this.desc,
    required this.scheme,
  });

  final IconData icon;
  final String title;
  final String desc;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: scheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
