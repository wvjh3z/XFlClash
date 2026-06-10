/// 在线客服接入（Crisp，D9 / 形态 A「帮助与客服」入口）。
///
/// **平台**（spec：支持 Android + macOS + Windows + Linux，不含 iOS）：
/// - Android：Crisp 原生 SDK（`crisp_chat` 插件透传）。
/// - macOS / Windows / Linux：Crisp Web Chat SDK 套 `desktop_webview_window` 嵌入窗口
///   （WebView 不可用时插件自动降级到系统浏览器）。
///
/// **配置**：websiteId 走 `XboardConfig.current.crispWebsiteId`（flavor 注入
/// `XB_CRISP_WEBSITE_ID`，NFR-2 零硬编码）。空串 = 未配置 → [isEnabled] false，
/// 「帮助与客服」入口隐藏（不暴露空会话）。
///
/// **带给客服的上下文**（已登录用户，关联工单）：
/// - 邮箱 → `User.email`（身份卡，便于客服检索）；昵称取邮箱前缀（会话列表易读）。
/// - 套餐名 / 到期时间 / 剩余流量 → `setSessionString`（客服后台「会话数据」面板可见）。
/// - 来源平台（Android/Windows/macOS/Linux）→ `sessionSegment` + 会话数据「来源」。
/// - 设备区域（locale 国家码，如 CN/US）→ `GeoLocation.country`。**诚实局限**：app 不采集
///   用户精确城市，city 留空；Crisp 服务端本身会按访客 IP 自动定位，此处仅补设备区域信号。
///
/// **复用边界**：本服务是 ◇ Xboard 自有代码（不经 FlClash adapter，无风险②）。
/// 游客（无订阅）只带来源平台，不带账号数据（匿名会话）。
///
/// **永不抛**（与 DD-2 一致）：平台调用失败（如桌面缺 WebKitGTK / 测试环境无插件）
/// 全捕获，仅 debugPrint，不让客服入口崩溃波及「我的」页。
library;

import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:crisp_chat/crisp_chat.dart';
import 'package:flutter/foundation.dart';

import '../config/xboard_config.dart';
import '../models/xb_domain_subscription.dart';
import '../util/format.dart';

/// Crisp 在线客服服务（静态封装，无状态）。
class CrispSupportService {
  CrispSupportService._();

  /// 当前 flavor 是否配置了 Crisp websiteId（决定「帮助与客服」入口是否显示）。
  static bool get isEnabled =>
      XboardConfig.current.crispWebsiteId.trim().isNotEmpty;

  /// 打开 Crisp 客服会话。
  ///
  /// [sub] 已登录账号订阅（从 `userProfileProvider` 取，携带邮箱/套餐/到期/流量）；
  /// 游客传 null（匿名会话，仅带来源平台）。
  /// 永不抛：平台异常全捕获（DD-2）。返回是否成功发起（失败 = false，调用方可 toast 兜底）。
  static Future<bool> open({XbDomainSubscription? sub}) async {
    final websiteId = XboardConfig.current.crispWebsiteId.trim();
    if (websiteId.isEmpty) return false; // 未配置（入口本应已隐藏，双重防御）。
    try {
      final email = sub?.email.trim();
      final hasEmail = email != null && email.isNotEmpty;

      final user = hasEmail
          ? User(
              email: email,
              nickName: email.split('@').first, // 邮箱前缀当显示名，会话列表易读。
              company: Company(
                geoLocation: GeoLocation(country: _deviceCountry()),
              ),
            )
          : null;

      final config = CrispConfig(
        websiteID: websiteId,
        user: user,
        sessionSegment: sourcePlatform, // 来源平台分段（configure 后由 setCrispData 设置）。
        enableNotifications: false, // 第一版不接推送（mobile FCM/APNs 未配置）。
      );

      // 先 open（内部 Crisp.configure 建立 session + 设置 user/segment）。
      await FlutterCrispChat.openCrispChat(config: config);

      // ⚠️ 会话自定义数据必须在 openCrispChat（= Crisp.configure）**之后**设置——
      // Crisp 原生 SDK 要求 session 就绪后 setSessionString 才生效（之前调会被丢弃，
      // 这是套餐/到期/流量曾传不过去的根因）。每次点击都重设一次（数据随最新订阅刷新）。
      _setStr('source', sourcePlatform);
      if (sub != null) {
        _setStr('plan', sub.planName ?? '未订阅');
        _setStr('expire', _expireText(sub));
        _setStr('remaining_traffic', '${xbGb(sub.remainingBytes)} GB');
        _setInt('used_percent', _usedPercent(sub));
      }
      return true;
    } catch (e, s) {
      debugPrint('[CrispSupportService] open failed: $e\n$s');
      return false;
    }
  }

  /// 来源平台标识（客服一眼看出用户从哪个端来）。
  static String get sourcePlatform {
    if (Platform.isAndroid) return 'Android 客户端';
    if (Platform.isIOS) return 'iOS 客户端';
    if (Platform.isWindows) return 'Windows 客户端';
    if (Platform.isMacOS) return 'macOS 客户端';
    if (Platform.isLinux) return 'Linux 客户端';
    return '未知客户端';
  }

  /// 设备区域国家码（locale countryCode，如 CN/US；缺失返 null）。真实设备区域设置，不编造。
  static String? _deviceCountry() {
    final cc = PlatformDispatcher.instance.locale.countryCode?.trim();
    return (cc == null || cc.isEmpty) ? null : cc;
  }

  /// 到期文案：长期有效 / 已过期 日期 / 日期（与账号卡口径一致）。
  static String _expireText(XbDomainSubscription sub) {
    final d = sub.expiredAt;
    if (d == null) return '长期有效';
    final ymd = xbDateMinute(d);
    return d.isAfter(DateTime.now()) ? ymd : '已过期 $ymd';
  }

  /// 已用流量百分比（整数，0~100）。
  static int _usedPercent(XbDomainSubscription sub) {
    if (sub.totalBytes <= 0) return 0;
    return xbPercentInt((sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0));
  }

  static void _setStr(String key, String value) {
    try {
      FlutterCrispChat.setSessionString(key: key, value: value);
    } catch (_) {/* 永不抛 */}
  }

  static void _setInt(String key, int value) {
    try {
      FlutterCrispChat.setSessionInt(key: key, value: value);
    } catch (_) {/* 永不抛 */}
  }
}
