/// R4.6 账号永久删除请求页（v0.1 mailto 路径 / 合规 § B / κ-3 GDPR Art 17 被遗忘权）。
///
/// **v0.1 最小路径**：跳系统邮件 App，预填客服邮箱 + 标题 `[xfork] 账号注销请求 - <userIdHash>`
/// （**不带** token / 完整 email，用 hash 反查），后端人工处理（v0.1 SDK 无 deleteAccount adapter）。
///
/// **v0.2 评估**：SDK 加 `auth.deleteAccount()` + 后端 endpoint，客户端一键自动化。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/xboard_config.dart';
import '../util/pii_mask.dart';

/// 构造账号注销 mailto URI（纯函数，便于测试 W4.7.5）。
Uri buildDeletionMailto({
  required String supportEmail,
  required String userIdHash,
}) {
  final subject = '[xfork] 账号注销请求 - $userIdHash';
  final body = '请删除我的账号及相关数据。\n\n用户 hash: $userIdHash\n\n（请在下方描述删除原因，便于我们核实处理）';
  return Uri(
    scheme: 'mailto',
    path: supportEmail,
    query: 'subject=${Uri.encodeQueryComponent(subject)}'
        '&body=${Uri.encodeQueryComponent(body)}',
  );
}

/// 账号注销请求页。[currentToken] 用于派生 userIdHash（注入便于测试）。
class AccountDeletionRequestPage extends ConsumerWidget {
  const AccountDeletionRequestPage({super.key, this.currentToken});

  /// 当前鉴权 token（派生 userIdHash 反查；测试可注入固定值）。
  final String? currentToken;

  Future<void> _requestDeletion(BuildContext context) async {
    final cfg = XboardConfig.current;
    final userIdHash = userIdHashFromToken(currentToken, length: 16);
    final mailto = buildDeletionMailto(
      supportEmail: cfg.supportEmail,
      userIdHash: userIdHash,
    );
    if (await canLaunchUrl(mailto)) {
      await launchUrl(mailto);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开邮件应用，请手动联系 ${cfg.supportEmail}')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('注销账号')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.no_accounts_outlined, size: 56, color: scheme.error),
              const SizedBox(height: 16),
              Text('永久删除账号',
                  textAlign: TextAlign.center,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                '账号注销将永久删除你的账号及相关数据（订阅、订单记录等），此操作不可撤销。\n\n'
                'v0.1 通过邮件人工处理：点击下方按钮会打开邮件应用并预填客服邮箱与你的账号标识'
                '（不含密码 / 完整邮箱）。请在邮件中描述删除原因后发送。',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ),
                onPressed: () => _requestDeletion(context),
                icon: const Icon(Icons.mail_outline_rounded),
                label: const Text('发送注销请求邮件'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
