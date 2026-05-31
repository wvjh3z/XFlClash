/// R5「我的服务」首页 —— **W1.4 stub**（walking skeleton 入口）。
///
/// W4.1 扩展为正式实现（authState 切换登录入口 vs 账号卡 + 首次离线检测 + GDPR consent）。
/// 当前仅占位让 W1 walking skeleton 可点击进入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「我的服务」主页（Xboard 主 Tab 的目标页）。
class XboardServiceHomePage extends ConsumerWidget {
  const XboardServiceHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(
      body: Center(
        child: Text('我的服务'),
      ),
    );
  }
}
