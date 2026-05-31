/// GDPR / 数据出境告知 consent dialog（合规 § A / κ-1 + κ-2 + κ-7 / DD-22）。
///
/// **触发时机**：首次进入「我的服务」（非 App 首启，避免阻塞 FlClash VPN 主路径）。
/// 未同意则禁用所有 Xboard 功能（仍可用 FlClash VPN）。
///
/// **三段文案**：
///   1. 数据收集范围：邮箱 / uuid / 订阅记录 / 订单记录 / 出口 IP（IpAuth 后端）
///   2. 跨境传输：服务器位置（flavor `dataResidency`）+ 数据控制方（`dataController`）
///   3. 第三方 SDK：Sentry（crash 跟踪，可在设置中关闭）
///
/// **链接**：用户协议（flavor `termsUrl`）+ 隐私政策（`privacyUrl`），用 url_launcher 打开。
///
/// **持久化**：同意写 `xb_consent_v1 = true`（schemaVersion=1）；拒绝不写值（下次再弹）。
/// Schema 升级（DD-22 / κ-1）：未来 GDPR 政策变更升 `xb_consent_v2` key 重新弹。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/xboard_config.dart';

/// consent 持久化 key（DD-22 v1；schema 升级时改 v2 重新弹）。
const String kXbConsentKey = 'xb_consent_v1';

/// GDPR 数据出境告知 dialog。
class XboardConsentDialog {
  const XboardConsentDialog._();

  /// 是否已同意（读 SharedPreferences）。
  static Future<bool> hasConsented() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kXbConsentKey) ?? false;
  }

  /// 确保已取得同意。已同意 → 直接 true（不弹）；否则弹窗：
  /// 同意 → 写 `xb_consent_v1=true` 返 true；拒绝 / 关闭 → 不写值返 false（下次再弹）。
  static Future<bool> ensureConsent(BuildContext context) async {
    if (await hasConsented()) return true;
    if (!context.mounted) return false;

    final agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ConsentDialogBody(),
    );

    if (agreed ?? false) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kXbConsentKey, true);
      return true;
    }
    return false;
  }
}

class _ConsentDialogBody extends StatelessWidget {
  const _ConsentDialogBody();

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = XboardConfig.current;
    final scheme = Theme.of(context).colorScheme;
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;

    return AlertDialog(
      title: const Text('数据与隐私告知'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Section(
              icon: Icons.dataset_outlined,
              title: '我们会收集',
              body: '邮箱、账号 UUID、订阅记录、订单记录，以及连接时的出口 IP'
                  '（用于订阅地址防滥用）。',
            ),
            _Section(
              icon: Icons.public_outlined,
              title: '数据存储与跨境',
              body: '数据存储于「${cfg.dataResidency}」，数据控制方为 '
                  '「${cfg.dataController}」。使用即表示你了解数据可能跨境传输。',
            ),
            const _Section(
              icon: Icons.bug_report_outlined,
              title: '第三方 SDK',
              body: '我们使用 Sentry 收集崩溃信息以改进稳定性（默认不含个人身份信息），'
                  '可在设置中关闭。',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                TextButton(
                  onPressed: () => _open(cfg.termsUrl),
                  child: const Text('用户协议'),
                ),
                TextButton(
                  onPressed: () => _open(cfg.privacyUrl),
                  child: const Text('隐私政策'),
                ),
              ],
            ),
            Text(
              '不同意不影响你继续使用 VPN 基础功能。',
              style: bodyStyle?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('暂不'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('同意并继续'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
