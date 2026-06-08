/// 形态 A 全局加载遮罩（spec `xboard-form-a-ui-revamp` / W3 UX）。
///
/// **用途**：按钮点击后需先 `await` 异步（拉数据再跳转 / 提交）时，弹一层**淡化半透明遮罩 +
/// 居中加载卡**覆盖全屏，让用户明确"正在处理"并**阻断重复点击**（遮罩 barrierDismissible:false
/// 吃掉所有手势），操作完成自动消失。替代各按钮内嵌转圈的零散写法。
///
/// **为何不用按钮内转圈**：按钮转圈只换了图标，用户仍可连点页面其它区域 / 快速双击；且每处
/// 自己管 `_busy` 易漏。全局遮罩一处收口：① 视觉统一（淡化等待，不是孤零零一个圈）
/// ② 物理阻断连点（模态屏障）③ 调用方一行 `await xbRunWithLoading(...)`。
///
/// 用法：
/// ```dart
/// final plans = await xbRunWithLoading(context, () => service.getPlans());
/// if (!context.mounted) return;
/// xbPush(context, PlanDetailPage(...));
/// ```
library;

import 'package:flutter/material.dart';

import 'xb_theme.dart' show XbTokens;

/// 是否已有遮罩在显示（防重入：嵌套调用只显示一层）。
bool _overlayShown = false;

/// 显示加载遮罩，跑 [action]，无论成败/异常都关闭遮罩，返回 action 结果。
///
/// - [message]：可选提示文案（默认「请稍候…」）。
/// - 重入安全：已有遮罩时不再叠加（[action] 仍执行）。
/// - 永远关闭：action 抛异常会 rethrow，但遮罩已在 finally 关闭。
/// - mounted 安全：context 失效不强行关闭（路由已变则遮罩随之销毁）。
Future<T> xbRunWithLoading<T>(
  BuildContext context,
  Future<T> Function() action, {
  String message = '请稍候…',
}) async {
  // 已有遮罩 → 不重复弹（嵌套场景），直接跑 action。
  if (_overlayShown) return action();

  _overlayShown = true;
  final navigator = Navigator.of(context, rootNavigator: true);
  // 用模态屏障实现「阻断连点 + 淡化遮罩」。barrierDismissible:false → 点遮罩无效。
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    useRootNavigator: true,
    builder: (_) => _XbLoadingCard(message: message),
  );

  try {
    return await action();
  } finally {
    _overlayShown = false;
    // 关闭遮罩 dialog（若仍在栈顶）。
    if (navigator.canPop()) navigator.pop();
  }
}

/// 居中加载卡（淡化遮罩之上）：圆角卡 + 旋转指示 + 文案。
class _XbLoadingCard extends StatelessWidget {
  const _XbLoadingCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(XbTokens.rLg),
            boxShadow: t.shadow2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                    strokeWidth: 2.6, color: scheme.primary),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                style: TextStyle(fontSize: 13.5, color: t.onv),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
