/// 在线客服接入（Crisp，D9 / 形态 A「帮助与客服」入口）。
///
/// **平台**（spec：支持 Android + macOS + Windows + Linux，不含 iOS）：
/// - Android：Crisp 原生 SDK（`crisp_chat` 插件透传）。
/// - macOS / Windows / Linux：Crisp Web Chat SDK 套 `desktop_webview_window` 嵌入窗口
///   （WebView 不可用时返回失败，不跳转运营后台）。
///
/// **配置**：websiteId 走 `XboardConfig.current.crispWebsiteId`（flavor 注入
/// `XB_CRISP_WEBSITE_ID`，NFR-2 零硬编码）。空串 = 未配置 → [isEnabled] false，
/// 「帮助与客服」入口隐藏（不暴露空会话）。
///
/// **带给客服的上下文**（已登录用户，关联工单）—— 字段对齐 EZ-Xbaord / Crisp_bot 格式：
/// - 邮箱 → `User.email`（身份卡，bot 读顶层 email）；昵称取邮箱前缀（会话列表易读）。
/// - 会话数据（`setSessionString`，Crisp 后台「会话数据」面板可见，bot `_META_FIELDS` 消费）：
///   `Email` / `Plan`(套餐名) / `Expires`(到期) / `Traffic`(剩余流量 GB) / `Source`(来源平台+客户端版本)。
/// - 设备区域（locale 国家码，如 CN/US）→ `GeoLocation.country`。**诚实局限**：app 不采集
///   用户精确城市，city 留空；Crisp 服务端本身会按访客 IP 自动定位，此处仅补设备区域信号。
///
/// > **字段对齐说明**：键名严格用 Crisp_bot `formatters._META_FIELDS` 的大写键（`Plan/Expires/
/// > Traffic/Balance`）+ EZ-Xbaord `CustomerService.vue` 的 `{Email,Plan,Expires,Traffic}`。
/// > `Balance`(余额) 本端无数据源（SDK getSubscribe 不含余额），暂不发；`Source` 是本端附加
/// > （bot 默认不渲染，需在 bot `_META_FIELDS` 加 `Source` 才在 TG 显示，Crisp 后台始终可见）。
///
/// **复用边界**：本服务是 ◇ Xboard 自有代码（不经 FlClash adapter，无风险②）。
/// 游客（无订阅）只带来源平台，不带账号数据（匿名会话）。
///
/// **永不抛**（与 DD-2 一致）：平台调用失败（如桌面缺 WebKitGTK / 测试环境无插件）
/// 全捕获，仅 debugPrint，不让客服入口崩溃波及「我的」页。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:crisp_chat/crisp_chat.dart';
import 'package:flutter/foundation.dart';

import '../config/xboard_config.dart';
import '../models/xb_domain_subscription.dart';
import '../util/app_version.dart' show myClientVersionLabel;
import '../util/format.dart' show xbDate;
import 'crisp_chat_driver.dart';

/// Crisp 在线客服服务（静态门面，串行会话生命周期）。
class CrispSupportService {
  CrispSupportService._();

  /// 当前 flavor 是否配置了 Crisp websiteId（决定「帮助与客服」入口是否显示）。
  static bool get isEnabled =>
      XboardConfig.current.crispWebsiteId.trim().isNotEmpty;

  static CrispChatDriver _driver = Platform.isAndroid || Platform.isIOS
      ? NativeCrispChatDriver()
      : DesktopCrispChatDriver();
  static Future<void> _queue = Future.value();
  static Future<bool>? _opening;
  static int _generation = 0;
  static Completer<void> _cancel = Completer<void>();
  static bool _resetFailed = false;

  @visibleForTesting
  static Future<void> setDriverForTest(CrispChatDriver driver) async {
    _generation++;
    if (!_cancel.isCompleted) _cancel.complete();
    await _queue;
    _driver = driver;
    _opening = null;
    _resetFailed = false;
    _cancel = Completer<void>();
  }

  static Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Coalesce repeated taps, wait for resets and bind all writes to this generation.
  static Future<bool> open({
    XbDomainSubscription? sub,
    bool Function()? isCurrent,
  }) {
    if (!isEnabled) return Future.value(false);
    if (_opening != null) return _opening!;
    final generation = _generation;
    final cancellation = _cancel.future;
    bool current() => generation == _generation && (isCurrent?.call() ?? true);
    final future = _serialized(() async {
      if (!current()) return false;
      final websiteId = XboardConfig.current.crispWebsiteId.trim();
      StreamSubscription<void>? events;
      var readySignal = Completer<void>();
      try {
        if (_resetFailed) {
          await _driver.reset(websiteId);
          _resetFailed = false;
        }
        if (!current()) return false;
        events = _driver.sessionLoaded.listen((_) {
          if (!readySignal.isCompleted) readySignal.complete();
        }, onError: (Object _) {});
        final email = sub?.email.trim();
        await _driver.open(
          CrispConfig(
            websiteID: websiteId,
            user: email == null || email.isEmpty
                ? null
                : User(
                    email: email,
                    nickName: email.split('@').first,
                    company: Company(
                      geoLocation: GeoLocation(country: _deviceCountry()),
                    ),
                  ),
            sessionSegment: sourcePlatform,
            enableNotifications: false,
          ),
        );
        final deadline = Stopwatch()..start();
        while (current() && deadline.elapsed < const Duration(seconds: 15)) {
          final sid = await _driver.sessionId().timeout(
            const Duration(seconds: 2),
            onTimeout: () => null,
          );
          if (!current()) return false;
          if (sid != null && sid.isNotEmpty) {
            final values = <String, String>{
              'Source': _sourceLabel,
              if (sub != null) ...{
                'Email': sub.email,
                'Plan': sub.planName ?? '未订阅套餐',
                'Expires': _expiresText(sub),
                'Traffic': '${_remainingGb(sub)} GB',
              },
            };
            for (final entry in values.entries) {
              if (!current()) return false;
              await _driver.setString(entry.key, entry.value);
            }
            return current();
          }
          await Future.any([
            cancellation,
            readySignal.future,
            Future<void>.delayed(const Duration(milliseconds: 500)),
          ]);
          readySignal = Completer<void>();
        }
        debugPrint('[CrispSupport] session_not_ready_or_cancelled');
        return false;
      } catch (error) {
        // Plugin exceptions may contain user email or session details.
        debugPrint(
          '[CrispSupport] open_or_session_data_failed type=${error.runtimeType}',
        );
        return false;
      } finally {
        await events?.cancel();
      }
    });
    _opening = future;
    unawaited(
      future.then((_) {
        if (identical(_opening, future)) _opening = null;
      }),
    );
    return future;
  }

  /// Invalidate pending work immediately; serialize native reset after in-flight writes.
  static Future<void> reset() {
    _generation++;
    if (!_cancel.isCompleted) _cancel.complete();
    _cancel = Completer<void>();
    _opening = null;
    final websiteId = XboardConfig.current.crispWebsiteId.trim();
    return _serialized(() async {
      try {
        await _driver.reset(websiteId);
        _resetFailed = false;
      } catch (_) {
        _resetFailed = true;
        debugPrint('[CrispSupport] reset_failed');
      }
    });
  }

  /// 来源平台标识（客服一眼看出用户从哪个端来）。
  static String get sourcePlatform {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return '未知';
  }

  /// 来源标签（会话数据 `Source`）：`平台(v{产品版本}-{buildTag})`，如
  /// `Android(v0.0.1-202606110630)`。客服可一眼看出端 + 客户端版本（排障用）。
  static String get _sourceLabel =>
      '$sourcePlatform(${myClientVersionLabel()})';

  /// 设备区域国家码（locale countryCode，如 CN/US；缺失返 null）。真实设备区域设置，不编造。
  static String? _deviceCountry() {
    final cc = PlatformDispatcher.instance.locale.countryCode?.trim();
    return (cc == null || cc.isEmpty) ? null : cc;
  }

  /// 到期文案（会话数据 `Expires`）：对齐 EZ-Xbaord —— 无到期 → `无限期`；否则 `YYYY-MM-DD`。
  static String _expiresText(XbDomainSubscription sub) {
    final d = sub.expiredAt;
    return d == null ? '无限期' : xbDate(d);
  }

  /// 剩余流量 GB（保留 2 位小数，对齐 EZ-Xbaord `remainingGB.toFixed(2)`）。
  static String _remainingGb(XbDomainSubscription sub) =>
      (sub.remainingBytes / (1024 * 1024 * 1024)).toStringAsFixed(2);
}
