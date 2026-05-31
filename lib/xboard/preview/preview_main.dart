/// 🔍 Xboard 页面**独立预览入口**（仅开发预览用，不进 release 树的运行路径）。
///
/// **为何独立**：完整 App 需原生工具链（Ninja/Rust/CXX）跑 VPN/Clash 内核，headless 环境跑不起来。
/// 本入口**只渲染 Xboard「我的服务」相关页面** + 注入 fake 反腐层（不联网、不启 FlClash 内核），
/// 用 `flutter run -d web-server --web-port 8080` 即可在浏览器看真实渲染效果（含 CJK 字体，
/// CanvasKit 自动拉 Noto 兜底字形）。
///
/// 运行：
/// ```
/// flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0 \
///   -t lib/xboard/preview/preview_main.dart
/// ```
/// 然后浏览器访问 http://<服务器IP>:8080
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pages/account_deletion_request_page.dart';
import '../pages/forgot_password_page.dart';
import '../pages/login_page.dart';
import '../pages/register_page.dart';
import '../pages/xboard_service_home_page.dart';
import '../providers/auth_state_provider.dart';
import '../providers/xboard_connectivity_provider.dart';
import '../providers/xboard_providers.dart';
import '../widgets/account_info_card.dart';
import '../widgets/xb_ui_kit.dart';
import 'fake_xboard_service.dart';

/// 预览品牌色（与 flavor 默认品牌红 D3 一致）。
const _brandColor = Color(0xFFD92E1A);

void main() {
  runApp(
    ProviderScope(
      overrides: [
        // 注入 fake 反腐层，所有调用返回可控假数据，不联网。
        xboardServiceProvider.overrideWithValue(FakeXboardService()),
        // 预览态：SDK 已就绪 + 非首次 + 在线 + 已登录（让首页直接展示账号卡）。
        bootstrapReadyProvider.overrideWith(() => _PreviewReady()),
        firstLaunchProvider.overrideWith(() => _PreviewFirst()),
        isOfflineProvider.overrideWith((ref) => false),
        authStateProvider.overrideWith(() => _PreviewAuth()),
      ],
      child: const _PreviewApp(),
    ),
  );
}

class _PreviewReady extends BootstrapReady {
  @override
  bool build() => true;
}

class _PreviewFirst extends FirstLaunch {
  @override
  bool build() => false;
}

class _PreviewAuth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  ThemeMode _mode = ThemeMode.light;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Xboard 页面预览',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandColor,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(primary: _brandColor, onPrimary: Colors.white),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandColor,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ),
      ),
      themeMode: _mode,
      home: _PreviewGallery(
        themeMode: _mode,
        onToggleTheme: () => setState(
          () => _mode = _mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light,
        ),
      ),
    );
  }
}

/// 预览导航首页 —— 列出可预览的 Xboard 页面入口 + 明暗主题切换。
class _PreviewGallery extends StatelessWidget {
  const _PreviewGallery({required this.themeMode, required this.onToggleTheme});

  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = themeMode == ThemeMode.dark;
    final entries = <_PreviewEntry>[
      _PreviewEntry(
        title: '我的服务首页',
        subtitle: 'R5 · XboardServiceHomePage（游客/登录态切换）',
        icon: Icons.dashboard_rounded,
        builder: (_) => const XboardServiceHomePage(brandColor: _brandColor),
      ),
      _PreviewEntry(
        title: '登录页',
        subtitle: 'R2 · XboardLoginPage',
        icon: Icons.login_rounded,
        builder: (_) => const XboardLoginPage(brandColor: _brandColor),
      ),
      _PreviewEntry(
        title: '注册页',
        subtitle: 'R1 · XboardRegisterPage（DD-9 二步登录）',
        icon: Icons.person_add_alt_1_rounded,
        builder: (_) => const XboardRegisterPage(brandColor: _brandColor),
      ),
      _PreviewEntry(
        title: '忘记密码页',
        subtitle: 'R3 · XboardForgotPasswordPage（持久化倒计时）',
        icon: Icons.lock_reset_rounded,
        builder: (_) => const XboardForgotPasswordPage(brandColor: _brandColor),
      ),
      _PreviewEntry(
        title: '账号信息卡',
        subtitle: 'R6 · AccountInfoCard（流量/到期/重置）',
        icon: Icons.account_circle_rounded,
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('账号信息')),
          body: const Padding(
            padding: EdgeInsets.all(16),
            child: AccountInfoCard(),
          ),
        ),
      ),
      _PreviewEntry(
        title: '注销账号',
        subtitle: 'R4.6 · AccountDeletionRequestPage（mailto）',
        icon: Icons.no_accounts_rounded,
        builder: (_) => const AccountDeletionRequestPage(currentToken: 'preview-token'),
      ),
    ];

    return XbBrandTheme(
      brandColor: _brandColor,
      child: Builder(builder: (context) {
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: const Text('Xboard 页面预览'),
            actions: [
              IconButton(
                tooltip: isDark ? '切换浅色' : '切换深色',
                icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
                onPressed: onToggleTheme,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      const Center(child: XbBrandBadge(size: 64)),
                      const SizedBox(height: 16),
                      Text(
                        'v0.1 形态 B 认证页面',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '点击进入任意页面查看真实渲染（fake 数据，不联网）',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 24),
                      for (final e in entries) ...[
                        _PreviewCard(entry: e),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _PreviewEntry {
  const _PreviewEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.entry});

  final _PreviewEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: entry.builder),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: Icon(entry.icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            )),
                    const SizedBox(height: 2),
                    Text(entry.subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            )),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
