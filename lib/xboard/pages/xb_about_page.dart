/// 形态 A 自定义关于页（原型 #15c）。
///
/// 展示: app logo + 名称 + 版本号 + 内核版本 + 「检查更新」按钮 + 有新版本提示 + 协议链接。
/// 从「我的」Tab「关于」行 push 进入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/xb_update_service.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/widgets/xb_center_toast.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandScaffold;
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

/// 自定义关于页。
class XbAboutPage extends ConsumerWidget {
  const XbAboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return XbBrandScaffold(
      title: '关于',
      body: _AboutBody(),
    );
  }
}

class _AboutBody extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AboutBody> createState() => _AboutBodyState();
}

class _AboutBodyState extends ConsumerState<_AboutBody> {
  bool _checking = false;

  Future<void> _checkForUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final sdk = ref.read(xboardSdkProvider);
      if (sdk == null) {
        if (mounted) {
          XbCenterToast.show(context, '服务未就绪，请稍后再试');
        }
        return;
      }
      final race = ref.read(injectedRaceControllerProvider);
      final result = await XbUpdateService.check(sdk, apiFailover: race?.failOverApi);
      if (!mounted) return;
      switch (result) {
        case UpdateAvailable(:final info):
          ref.read(availableUpdateProvider.notifier).set(info);
          showXbUpdateDialog(context, info);
        case UpdateNotAvailable():
          XbCenterToast.show(context, '已是最新版本 ✓',
              icon: Icons.check_circle_outline);
        case UpdateCheckFailed():
          XbCenterToast.show(context, '检查失败，请稍后重试',
              icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasUpdate = ref.watch(availableUpdateProvider) != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
      child: Column(
        children: [
          // App Logo
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(XboardConfig.current.brandColor).withValues(alpha: 0.85),
                  Color(XboardConfig.current.brandColor),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(XboardConfig.current.brandColor)
                      .withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Center(
              child: Text('M',
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: Colors.white)),
            ),
          ),
          const SizedBox(height: 16),
          // App Name
          Text('MyClient',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
          const SizedBox(height: 4),
          // Version
          Text(myClientVersionLabel(),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text('内核 FlClash 0.8.93',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          // Check Update Button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _checking ? null : _checkForUpdate,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('检查更新',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
          // Update available pill
          if (hasUpdate)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0x1E2E8B57),
                  border: Border.all(color: const Color(0x4D2E8B57)),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '🎉 有新版本啦',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2E8B57),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 32),
          // Links section
          _LinkTile(
            icon: Icons.gavel,
            label: '免责声明',
            onTap: () {},
          ),
          _LinkTile(
            icon: Icons.description_outlined,
            label: '用户协议',
            onTap: () {},
          ),
          _LinkTile(
            icon: Icons.shield_outlined,
            label: '隐私政策',
            onTap: () {},
          ),
          const SizedBox(height: 24),
          Text(
            '© 2025 MyClient · All rights reserved',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 14, color: scheme.onSurface))),
            Icon(Icons.chevron_right,
                size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
