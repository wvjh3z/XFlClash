/// 离线提示 banner（R11.4 / R10 / design L1380）。
///
/// 监听 `isOfflineProvider`（派生自 `xboardConnectivityProvider`，DD-5 单一数据源）；
/// 离线时显示顶部条「当前离线，部分数据可能陈旧」，网络恢复后自动隐藏（reactive）。
///
/// **不裸 listen 硬件**：测试 override `xboardConnectivityProvider` / `isOfflineProvider`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/xboard_connectivity_provider.dart';

/// 离线 banner —— 离线时显示，在线时收起（高度 0）。
class XboardOfflineBanner extends ConsumerWidget {
  const XboardOfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isOfflineProvider);
    final scheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      child: offline
          ? Container(
              width: double.infinity,
              color: scheme.tertiaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 18, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '当前离线，部分数据可能陈旧',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onTertiaryContainer),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
