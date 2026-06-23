/// 首启「欢迎 / 隐私安全」弹窗（form-a · 原型 L/J · 首启隐私弹窗）。
///
/// **替换上游 FlClash 首启的两个弹窗**（免责声明「学习交流/非商业」+ Android Crashlytics 提示）：
/// 二者与本商业产品性质不符（前者禁止商业用途，后者声称用 Firebase 实则未用），统一成本弹窗。
///
/// **触发**：App 首次安装打开（由 `lib/state.dart` `_handlerDisclaimer` 在 `disclaimerAccepted==false`
/// 时调用，接缝点 #seam-welcome）。**强制**：点「退出」关闭 App（上游 `handleExit`），
/// 点「同意并开始」才继续（调用方写 `disclaimerAccepted=true` 持久化，不再弹）。
///
/// **三段卖点**（文案锁定 2026-06-20，不提崩溃分析）：安全加密 / 数据存海外新加坡(PDPA) / 最小化收集。
/// 底部「用户协议」「隐私政策」可点 → in-app push [TermsPage] / [PrivacyPage]（非外链）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../config/xboard_config.dart';
import '../pages/legal_pages.dart' show TermsPage, PrivacyPage;
import 'xb_theme.dart' show xbShowDialog, xbPush, XbTokens;

/// 首启欢迎/隐私安全弹窗（对外唯一入口）。
class XbWelcomeDialog {
  const XbWelcomeDialog._();

  /// 弹出并等待用户选择。返回 `true`=同意并开始，`false`=退出（或异常兜底）。
  /// barrierDismissible=false：只能经按钮决策，不可点外部关闭。
  static Future<bool> show(BuildContext context) async {
    final res = await xbShowDialog<bool>(
      context: context,
      brandColor: Color(XboardConfig.current.brandColor),
      barrierDismissible: false,
      builder: (_) => const _WelcomeDialogBody(),
    );
    return res ?? false;
  }
}

class _WelcomeDialogBody extends StatefulWidget {
  const _WelcomeDialogBody();

  @override
  State<_WelcomeDialogBody> createState() => _WelcomeDialogBodyState();
}

class _WelcomeDialogBodyState extends State<_WelcomeDialogBody> {
  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _privacyTap;

  Color get _brand => Color(XboardConfig.current.brandColor);

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()
      ..onTap = () => xbPush(context, const TermsPage(), brandColor: _brand);
    _privacyTap = TapGestureRecognizer()
      ..onTap = () => xbPush(context, const PrivacyPage(), brandColor: _brand);
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      backgroundColor: t.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XbTokens.rLg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('欢迎使用',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: t.on)),
              const SizedBox(height: 6),
              Text('使用前，请了解以下隐私与安全说明',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: t.onv)),
              const SizedBox(height: 18),
              const Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Feature(
                        icon: Icons.lock_outline,
                        title: '安全加密',
                        desc: '采用业界标准的加密传输协议，为你的网络连接建立安全隧道，'
                            '有效防止数据在传输过程中被窃听或篡改。',
                      ),
                      _Feature(
                        icon: Icons.public,
                        title: '数据存于海外新加坡',
                        desc: '你的账号与订阅数据存储在位于新加坡的服务器，遵循新加坡'
                            '《个人数据保护法》(PDPA) 等当地数据保护标准妥善保管。',
                      ),
                      _Feature(
                        icon: Icons.verified_user_outlined,
                        title: '最小化收集',
                        desc: '我们仅收集为你提供服务所必需的信息（如邮箱、订阅与订单'
                            '记录），并采取加密等技术措施保护你的数据安全。',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  style: TextStyle(fontSize: 11.5, height: 1.65, color: t.onv),
                  children: [
                    const TextSpan(text: '继续使用即表示你已阅读并同意 '),
                    TextSpan(
                      text: '用户协议',
                      style: TextStyle(
                          color: scheme.primary, fontWeight: FontWeight.w600),
                      recognizer: _termsTap,
                    ),
                    const TextSpan(text: ' 与 '),
                    TextSpan(
                      text: '隐私政策',
                      style: TextStyle(
                          color: scheme.primary, fontWeight: FontWeight.w600),
                      recognizer: _privacyTap,
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: FilledButton.styleFrom(
                          backgroundColor: t.sfc,
                          foregroundColor: t.on,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(XbTokens.rMd)),
                        ),
                        child: const Text('退出'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(XbTokens.rMd)),
                        ),
                        child: const Text('同意并开始'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单段卖点行：品牌色圆角图标徽标 + 标题 + 描述。
class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.desc});

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.12), t.card),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 21, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: t.on)),
                const SizedBox(height: 3),
                Text(desc,
                    style:
                        TextStyle(fontSize: 12.5, height: 1.65, color: t.onv)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
