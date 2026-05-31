/// R12/R13 路由守卫 —— pendingDestination（决策 #15 / Property 22 / design 路由守卫章节）。
///
/// **What**：未登录用户点「需登录」子页时，先记录目标页（`XbRoute` enum + 可序列化参数），
/// 跳登录；登录成功后读取并用**当前 context** 经纯函数 [buildXbRoute] 构造目标页 push，再清 pending。
///
/// **🔴 为什么存 enum 而非 WidgetBuilder 闭包（第 11 轮 / Property 22）**：
/// 闭包会捕获来源页 State / BuildContext → ① 跳转时用陈旧 context；② 来源页销毁后闭包仍持引用
/// （泄漏）。改存「`XbRoute` + `Map<String,Object?> args`」（纯可序列化值），登录成功后用当前 context
/// 重建，无捕获、无泄漏、序列化等价（Property 22）。
library;

import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part '../generated/providers/pending_destination_provider.g.dart';

/// 需登录的 Xboard 目标路由（6 项闭合，决策 #15 / μ-11 三方对齐 / design 路由守卫章节）。
///
/// 闭合集：不增不减——v0.1 所有「需登录才能进」的页面恰好这 6 个。
enum XbRoute {
  /// 套餐列表（R8）。
  plans,

  /// 套餐详情（R8，args: planId）。
  planDetail,

  /// 结算页（R8，args: tradeNo / planId+period）。
  checkout,

  /// 订单列表（R9）。
  orders,

  /// 订单详情（R9，args: tradeNo）。
  orderDetail,

  /// 账号信息（R6）。
  account,
}

/// pending 目标 = 路由标识 + 参数（**不存** WidgetBuilder 闭包，Property 22）。
@immutable
class PendingDestination {
  const PendingDestination(this.route, [this.args = const {}]);

  /// 目标路由。
  final XbRoute route;

  /// 路由参数（可序列化基本类型，如 `{'planId': 3}` / `{'tradeNo': 'xxx'}`）。
  final Map<String, Object?> args;

  @override
  bool operator ==(Object other) =>
      other is PendingDestination &&
      other.route == route &&
      _mapEquals(other.args, args);

  @override
  int get hashCode => Object.hash(route, Object.hashAllUnordered(args.entries.map((e) => Object.hash(e.key, e.value))));

  static bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || a[k] != b[k]) return false;
    }
    return true;
  }

  @override
  String toString() => 'PendingDestination(${route.name}, $args)';
}

/// pendingDestination 状态（keepAlive，跨登录页生命周期保留；登录成功消费后清 null）。
///
/// **UI 可 watch**：登录页 success 回调读取 + 清；路由守卫写入。
@Riverpod(keepAlive: true)
class PendingDestinationNotifier extends _$PendingDestinationNotifier {
  @override
  PendingDestination? build() => null;

  /// 记录目标页（跳登录前）。
  // ignore: use_setters_to_change_properties
  void set(PendingDestination destination) => state = destination;

  /// 消费并清空 —— 返回当前 pending（无则 null）并置 null（一次性，避免重复跳转）。
  PendingDestination? consume() {
    final current = state;
    state = null;
    return current;
  }

  /// 清空（取消跳转 / 用户主动返回）。
  void clear() => state = null;
}

/// 纯函数：由 [XbRoute] + args + **当前 context** 构造目标页 widget（Property 22 反序列化端）。
///
/// **纯函数约束**：只依赖入参（route/args/context），不捕获来源页 State；同一 (route,args)
/// 多次调用得到等价 widget tree（Property 22）。
///
/// **W3.11 占位**：plans/planDetail/checkout/orders/orderDetail/account 页面在 W6/W7 才建；
/// 当前返回带路由标识的占位页（[_XbRoutePlaceholder]），W6/W7 填实时替换 case 返回真实页面，
/// 守卫/序列化机制不变。
Widget buildXbRoute(XbRoute route, Map<String, Object?> args, BuildContext context) {
  return switch (route) {
    XbRoute.plans => const _XbRoutePlaceholder(title: '套餐列表', route: XbRoute.plans),
    XbRoute.planDetail =>
      _XbRoutePlaceholder(title: '套餐详情', route: XbRoute.planDetail, args: args),
    XbRoute.checkout =>
      _XbRoutePlaceholder(title: '结算', route: XbRoute.checkout, args: args),
    XbRoute.orders => const _XbRoutePlaceholder(title: '订单列表', route: XbRoute.orders),
    XbRoute.orderDetail =>
      _XbRoutePlaceholder(title: '订单详情', route: XbRoute.orderDetail, args: args),
    XbRoute.account => const _XbRoutePlaceholder(title: '账号信息', route: XbRoute.account),
  };
}

/// W3.11 占位页（W6/W7 替换为真实页面）。
class _XbRoutePlaceholder extends StatelessWidget {
  const _XbRoutePlaceholder({
    required this.title,
    required this.route,
    this.args = const {},
  });

  final String title;
  final XbRoute route;
  final Map<String, Object?> args;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$title（${route.name}）',
                style: Theme.of(context).textTheme.titleMedium),
            if (args.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('args: $args',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            const Text('W6/W7 填实'),
          ],
        ),
      ),
    );
  }
}
