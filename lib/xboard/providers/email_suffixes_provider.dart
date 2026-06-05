/// 邮箱注册白名单后缀 provider（form-a R5.6 / 决策 10）。
///
/// **职责**：调反腐层 `getEmailSuffixes()`（内部 SDK `getConfig().emailWhitelistSuffix`）取
/// 注册 / 忘记密码 sheet 的邮箱后缀下拉数据。
///
/// **仅 v2.0（formA）消费**：形态 B 的 F240「v0.1 SHALL NOT 调 getConfig」约束在 v2.0 已解除
/// （跨层前置依赖，W0.2）。
///
/// **fail-open 降级（R5.6 / F208）**：拉取失败 / 空列表 → 返回 `const []`，UI 据此放开任意
/// 后缀输入（不因配置接口故障阻塞注册）。永不抛（反腐层已 XbResult 归一，本 provider 再兜底）。
///
/// **keepAlive**：站点配置在 App 生命周期内基本不变；登录无关，进 sheet 时 watch 即可。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/xb_result.dart';
import 'xboard_providers.dart';

part '../generated/providers/email_suffixes_provider.g.dart';

/// 邮箱注册白名单后缀列表（R5.6）。
///
/// 成功 → 后缀列表（可空 = 白名单禁用）；失败 → `const []`（fail-open，不阻塞注册）。
@Riverpod(keepAlive: true)
Future<List<String>> emailSuffixes(Ref ref) async {
  final result = await ref.watch(xboardServiceProvider).getEmailSuffixes();
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure() => const <String>[], // fail-open：配置接口故障不阻塞注册（R5.6/F208）
  };
}
