/// R5「我的服务」首页 —— W4.1 正式实现（walking skeleton 终点）。
///
/// 渲染决策顺序（design § J 正交 gate）：
///   1. `bootstrapReady == false` → 配置加载异常 banner（DD-17 / F15）
///   2. `firstLaunch && offline` → `_FirstOfflineSplash`（合规 § F / ι-3，登录/注册 disabled）
///   3. 首次未登录 → `XboardConsentDialog.ensureConsent`（合规 § A / κ-1）；未同意禁用功能
///   4. `authState`：authenticated → 账号卡（R6）+ 退出；其余 → 游客登录/注册引导（R5.3）
///
/// 顶部常驻 `XboardOfflineBanner`（R11.4）。从接缝点 #6「我的服务」入口进入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_state_provider.dart';
import '../providers/user_profile_provider.dart';
import '../providers/xboard_connectivity_provider.dart';
import '../providers/xboard_providers.dart';
import '../widgets/account_info_card.dart';
import '../widgets/xb_ui_kit.dart';
import '../widgets/xboard_consent_dialog.dart';
import '../widgets/xboard_offline_banner.dart';
import 'account_deletion_request_page.dart';
import 'login_page.dart';
import 'register_page.dart';

/// 「我的服务」主页（Xboard 主 Tab 的目标页）。
class XboardServiceHomePage extends ConsumerStatefulWidget {
  const XboardServiceHomePage({super.key, this.brandColor = const Color(0xFFD92E1A)});

  final Color brandColor;

  @override
  ConsumerState<XboardServiceHomePage> createState() => _XboardServiceHomePageState();
}

class _XboardServiceHomePageState extends ConsumerState<XboardServiceHomePage> {
  bool _consentChecked = false;
  bool _consentGranted = false;

  @override
  void initState() {
    super.initState();
    // 首帧后检查 consent（需 BuildContext，不能在 build 内弹 dialog）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureConsent());
  }

  Future<void> _ensureConsent() async {
    final granted = await XboardConsentDialog.ensureConsent(context);
    if (mounted) {
      setState(() {
        _consentChecked = true;
        _consentGranted = granted;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(bootstrapReadyProvider);
    final firstLaunch = ref.watch(firstLaunchProvider);
    final offline = ref.watch(isOfflineProvider);
    final auth = ref.watch(authStateProvider);

    return XbBrandTheme(
      brandColor: widget.brandColor,
      child: Builder(builder: (context) {
        return Scaffold(
          appBar: AppBar(title: const Text('我的服务')),
          body: Column(
            children: [
              const XboardOfflineBanner(),
              Expanded(child: _body(context, ready, firstLaunch, offline, auth)),
            ],
          ),
        );
      }),
    );
  }

  Widget _body(BuildContext context, bool ready, bool firstLaunch, bool offline,
      AuthState auth) {
    // 1. SDK 未就绪（fallback 损坏）→ 配置异常 banner（DD-17 / F15）。
    if (!ready) {
      return const _CenteredMessage(
        icon: Icons.settings_suggest_outlined,
        title: '配置加载异常',
        body: '初始化未完成，请重启应用后重试。',
      );
    }
    // 2. 首次安装 + 完全离线 → 提示页（合规 § F / ι-3）。
    if (firstLaunch && offline) {
      return _FirstOfflineSplash(onCheckNetwork: () {
        // 跳系统网络设置（v0.1 占位 toast；真实跳转在平台层 W5+ 接）。
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请在系统设置中检查网络连接')),
        );
      });
    }
    // 3. 首次未登录且未同意 consent → 禁用功能提示（已同意/已登录跳过）。
    if (_consentChecked && !_consentGranted && auth != AuthState.authenticated) {
      return _ConsentRequiredView(onReview: _ensureConsent);
    }
    // 4. authState 分流。
    return switch (auth) {
      AuthState.authenticated => _LoggedInView(brandColor: widget.brandColor),
      _ => _GuestView(brandColor: widget.brandColor),
    };
  }
}

/// 已登录视图（R5.4）：账号卡 + 退出登录 + 注销账号入口。
class _LoggedInView extends ConsumerWidget {
  const _LoggedInView({required this.brandColor});
  final Color brandColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(userProfileProvider), // R6.4 下拉刷新
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AccountInfoCard(),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => ref.read(authStateProvider.notifier).logout(), // R4.5
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('退出登录'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AccountDeletionRequestPage(),
              ),
            ),
            child: const Text('注销账号'),
          ),
        ],
      ),
    );
  }
}

/// 游客视图（R5.3）：登录 / 注册引导。
class _GuestView extends StatelessWidget {
  const _GuestView({required this.brandColor});
  final Color brandColor;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: XbBrandBadge()),
              const SizedBox(height: 24),
              Text('登录管理你的服务',
                  textAlign: TextAlign.center,
                  style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('登录后查看订阅、套餐与订单',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 32),
              XbPrimaryButton(
                label: '登录',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => XboardLoginPage(brandColor: brandColor),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => XboardRegisterPage(brandColor: brandColor),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('注册新账号'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首次离线提示页（合规 § F / ι-3）—— 登录/注册按钮 disabled。
class _FirstOfflineSplash extends StatelessWidget {
  const _FirstOfflineSplash({required this.onCheckNetwork});
  final VoidCallback onCheckNetwork;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text('需要网络连接',
                textAlign: TextAlign.center,
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('初次使用「我的服务」需要联网注册账号。\n请连接网络后重试。',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            // 登录/注册 disabled（首次离线无法注册）。
            const _DisabledButton(label: '登录'),
            const SizedBox(height: 12),
            const _DisabledButton(label: '注册新账号'),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCheckNetwork,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('检查网络'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisabledButton extends StatelessWidget {
  const _DisabledButton({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: null, // disabled（首次离线，合规 § F）
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(label),
      ),
    );
  }
}

/// 未同意 consent 时的禁用功能视图。
class _ConsentRequiredView extends StatelessWidget {
  const _ConsentRequiredView({required this.onReview});
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.privacy_tip_outlined, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('需要同意数据与隐私告知',
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('同意后才能使用「我的服务」账号功能；不影响 VPN 基础功能。',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            FilledButton(onPressed: onReview, child: const Text('查看并同意')),
          ],
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage(
      {required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
