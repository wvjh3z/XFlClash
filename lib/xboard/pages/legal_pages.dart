/// 法律协议三页（form-a · 原型 K/I · 法律协议 section）：免责声明 / 用户协议 / 隐私政策。
///
/// 从「关于」页（[XbAboutPage]）的协议菜单 push 进入，**免登录可看**（纯静态条款，无网络）。
/// 内容定稿：主体用「本应用 / 本服务」，联系方式为应用内「在线客服」，数据存储位置 = 新加坡，
/// 适用法律 = 新加坡。用户协议行为规范含《互联网信息服务管理办法》第十五条「九不准」
/// （宪法/国家/民族等特指中华人民共和国）+ 技术滥用兜底。
///
/// 排版对齐 [TutorialDetailPage]：标题 + 最近更新元行 + 分隔线 + 分节正文，桌面宽窗限宽 680。
library;

import 'package:flutter/material.dart';

import '../widgets/xb_components.dart' show XbInfoCard;
import '../widgets/xb_theme.dart' show XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;

// ───────── 共享排版工具 ─────────

/// 法律页通用骨架：品牌 AppBar + 滚动正文（标题 + 更新时间 + 分隔线 + [children]），桌面限宽 680。
class _LegalScaffold extends StatelessWidget {
  const _LegalScaffold({
    required this.title,
    required this.docTitle,
    required this.updatedAt,
    required this.children,
  });

  final String title;
  final String docTitle;
  final String updatedAt;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return XbBrandScaffold(
      title: title,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(docTitle,
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                        color: t.on)),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Icon(Icons.schedule, size: 15, color: t.onv),
                    const SizedBox(width: 6),
                    Text('最近更新 $updatedAt',
                        style: TextStyle(fontSize: 11.5, color: t.onv)),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(height: 1, thickness: 1, color: t.hair),
                const SizedBox(height: 14),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 正文段落。
Widget _p(BuildContext context, String text, {bool bold = false}) {
  final t = XbTokens.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text,
        style: TextStyle(
            fontSize: 14,
            height: 1.85,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            color: t.on)),
  );
}

/// 分节标题。
Widget _h(BuildContext context, String text) {
  final t = XbTokens.of(context);
  return Padding(
    padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
    child: Text(text,
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600, color: t.on)),
  );
}

/// 无序列表（圆点 + 文本）。
Widget _bullets(BuildContext context, List<String> items) {
  final t = XbTokens.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 9, left: 2),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                        color: t.onv, shape: BoxShape.circle),
                  ),
                ),
                Expanded(
                  child: Text(it,
                      style: TextStyle(
                          fontSize: 14, height: 1.7, color: t.on)),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 底部品牌色提示框（复用 [XbInfoCard]）。
Widget _tip(String text) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: XbInfoCard(icon: Icons.info_outline, text: text),
    );

// ───────── 免责声明 ─────────

/// 免责声明页（关于 → 免责声明）。
class DisclaimerPage extends StatelessWidget {
  const DisclaimerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: '免责声明',
      docTitle: '免责声明',
      updatedAt: '2026-06-20',
      children: [
        _p(context,
            '本应用是一款网络代理工具客户端，本身不提供任何信息内容服务，仅在用户主动配置并启用代理后转发用户的网络流量。继续使用本应用即视为您已阅读、理解并同意本声明。'),
        _h(context, '一、服务性质'),
        _bullets(context, const [
          '本应用提供节点选择、连接管理、流量统计等技术工具',
          '不审查、缓存、记录用户访问的任何具体内容',
          '不对节点服务的可用性、稳定性、连接速度作出连续性承诺',
        ]),
        _h(context, '二、用户责任'),
        _bullets(context, const [
          '您应遵守所在国家或地区的法律法规，不得使用本应用从事违法违规活动',
          '您对自己通过本应用进行的网络行为承担全部责任，包括访问的内容、传输的数据',
          '因您违反法律法规或本声明造成的一切后果，由您自行承担',
        ]),
        _h(context, '三、风险提示'),
        _bullets(context, const [
          '网络服务受运营商、链路、网关等多方因素影响，可能发生延迟、丢包、中断',
          '不可抗力（自然灾害、政策变化、第三方服务中断等）导致的服务异常，恕不承担责任',
        ]),
        _h(context, '四、内容引用'),
        _bullets(context, const [
          '本应用基于开源核心 FlClash（GPL-3.0）二次开发，遵循其开源协议',
          '第三方品牌名称、商标、Logo 归各自权利人所有',
        ]),
        _tip('本声明的最终解释权归服务提供方所有，并可能随服务调整而更新。'),
      ],
    );
  }
}

// ───────── 用户协议 ─────────

/// 用户协议页（关于 → 用户协议）。
class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: '用户协议',
      docTitle: '用户协议',
      updatedAt: '2026-06-20',
      children: [
        _p(context, '欢迎使用本服务。请在使用前仔细阅读本协议，您完成注册或使用服务即视为同意本协议全部内容。'),
        _h(context, '一、服务说明'),
        _bullets(context, const [
          '本服务提供网络加速、节点订阅、连接管理等技术功能',
          '服务通过订阅套餐方式提供，具体配额、速率、有效期以您所购套餐为准',
        ]),
        _h(context, '二、账号注册与使用'),
        _bullets(context, const [
          '您应使用真实有效的邮箱注册账号，并妥善保管账号密码',
          '一个账号仅供您本人使用，禁止借用、共享、转售、批量注册',
          '账号被盗用、密码泄露造成的损失由您自行承担',
        ]),
        _h(context, '三、用户行为规范'),
        _p(context, '您承诺不会利用本服务从事以下行为（本节中所称「宪法」「国家」「民族」等，均特指中华人民共和国）：'),
        _bullets(context, const [
          '反对宪法所确定的基本原则、危害国家安全、颠覆国家政权、破坏国家统一',
          '损害国家荣誉和利益，煽动民族仇恨、破坏民族团结',
          '破坏国家宗教政策，宣扬邪教或封建迷信',
          '散布谣言、扰乱社会秩序、破坏社会稳定',
          '散布淫秽、色情、赌博、暴力、恐怖或教唆犯罪的信息',
          '侮辱、诽谤他人或侵害他人合法权益',
          '网络攻击、入侵、爬虫、DDoS 等危害网络安全的行为',
          '滥用流量、刷接口、对节点发起异常请求等损害服务可用性的行为',
          '将服务用于商业转售或再分发',
          '其他法律、行政法规禁止的行为',
        ]),
        _h(context, '四、订阅与付款'),
        _bullets(context, const [
          '订阅周期内的服务自购买之日起算，到期后服务自动停止',
          '已付款项除法定情形外不予退款',
          '套餐特权、流量配额、节点权限以套餐说明为准',
        ]),
        _h(context, '五、违约处理'),
        _bullets(context, const [
          '您违反本协议或法律法规的，我们有权立即暂停或终止服务，并保留追究法律责任的权利',
          '因违规导致的封号、扣除流量、清除订阅记录等措施不予退款',
        ]),
        _h(context, '六、服务与协议变更'),
        _bullets(context, const [
          '我们可能根据运营需要调整套餐、节点、价格、功能；重大变更将提前通知',
          '本协议可能随服务调整而更新，最新版本以应用内或官网公示为准',
          '您继续使用服务即视为同意更新后的协议',
        ]),
        _h(context, '七、争议解决'),
        _bullets(context, const [
          '本协议的解释与执行适用新加坡法律',
          '协商不成的争议可提交服务提供方所在地有管辖权的法院诉讼',
        ]),
        _tip('如对协议条款有疑问，请通过应用内「在线客服」联系我们。'),
      ],
    );
  }
}

// ───────── 隐私政策 ─────────

/// 隐私政策页（关于 → 隐私政策）。
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: '隐私政策',
      docTitle: '隐私政策',
      updatedAt: '2026-06-20',
      children: [
        _p(context, '我们重视您的隐私。本政策说明本应用收集哪些信息、如何使用、如何保护，以及您拥有哪些权利。'),
        _h(context, '一、我们收集的信息'),
        _p(context, '1. 账号信息', bold: true),
        _bullets(context, const [
          '邮箱（用于登录与重要通知）',
          '账号 UUID（系统生成的唯一标识）',
          '加密后的密码（不可还原）',
        ]),
        _p(context, '2. 订阅与订单信息', bold: true),
        _bullets(context, const [
          '套餐、订单记录、支付状态（不存储完整支付凭证）',
          '套餐流量使用情况、到期时间',
        ]),
        _p(context, '3. 连接信息', bold: true),
        _bullets(context, const [
          '出口 IP（用于防止账号滥用、异常登录检测）',
          '我们不记录您具体访问的网站、应用、内容',
        ]),
        _p(context, '4. 设备与崩溃信息', bold: true),
        _bullets(context, const [
          '设备型号、操作系统版本（兼容性排查）',
          '应用崩溃堆栈（已脱敏，不含 token / 密码 / 邮箱等）',
          '可在「设置 → 关闭崩溃分析」关闭此项收集',
        ]),
        _h(context, '二、我们如何使用信息'),
        _bullets(context, const [
          '提供账号登录、订阅服务、套餐管理等核心功能',
          '防止账号被盗、批量注册、流量滥用',
          '改进应用稳定性与功能（仅基于聚合数据）',
          '处理客服咨询与售后请求',
        ]),
        _h(context, '三、数据存储位置'),
        _bullets(context, const [
          '账号、订阅、订单数据存储于：新加坡',
          '数据控制方：本服务的运营方',
        ]),
        _h(context, '四、第三方服务'),
        _p(context, '我们使用以下第三方服务，仅传递必要信息：'),
        _bullets(context, const [
          'Sentry：崩溃信息上报，默认开启 PII 脱敏；可在设置中关闭',
          '支付服务商（支付宝 / 微信等）：仅获取订单状态，不接触您的支付凭证',
        ]),
        _h(context, '五、数据保留'),
        _bullets(context, const [
          '账号信息：账号有效期内长期保存',
          '订单记录：保留 1 年（含税务/财务合规要求）',
          '崩溃日志：30 天',
        ]),
        _h(context, '六、未成年人保护'),
        _p(context, '本服务不面向 18 岁以下用户。我们不会主动收集未成年人个人信息，若发现已收集，将立即删除。'),
        _h(context, '七、政策变更'),
        _p(context, '本政策可能随服务调整而更新，重大变更将通过应用内通知或邮件告知。'),
        _h(context, '八、联系我们'),
        _p(context, '如对本政策有疑问，请通过应用内「在线客服」联系我们。'),
        _tip('我们承诺：除法律强制要求外，不会出售、出租、转让您的个人信息。'),
      ],
    );
  }
}
