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

import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:crisp_chat/crisp_chat.dart';
import 'package:flutter/foundation.dart';

import '../config/xboard_config.dart';
import '../models/xb_domain_subscription.dart';
import '../util/app_version.dart' show myClientVersionLabel;
import '../util/format.dart' show xbDate;

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

      // ⚠️ Crisp session 是 open 后**异步**向服务端创建的（configure 后还要网络往返才
      // "loaded"）；插件无「session 就绪」回调，立即调 setSessionString 会被丢弃
      // （logcat: "Session not found for website"）。改为后台轮询 getSessionIdentifier，
      // 待 session 就绪后再写会话数据。fire-and-forget（不阻塞聊天界面），永不抛。
      unawaited(_applySessionDataWhenReady(sub));
      return true;
    } catch (e, s) {
      debugPrint('[CrispSupportService] open failed: $e\n$s');
      return false;
    }
  }

  /// 重置 Crisp 本地会话（登出/换号时调）。
  ///
  /// Crisp session 在设备上持久（含访客身份 email + 会话数据 + 聊天历史）。不 reset 的话：
  /// ① 登出后游客打开客服仍残留上一用户的 email/套餐等；② 换号登录后打开客服仍是旧 session
  /// 带旧账号信息。reset 后下次 open 会建全新 session（新账号带新数据 / 游客匿名）。
  /// 永不抛（DD-2）：无 session / 测试无插件时静默吞掉。
  static Future<void> reset() async {
    try {
      await FlutterCrispChat.resetCrispChatSession();
    } catch (e, s) {
      debugPrint('[CrispSupportService] reset failed: $e\n$s');
    }
  }

  /// 后台轮询 session 就绪后写会话数据（套餐/到期/流量/来源）。
  ///
  /// Crisp session 在 openCrispChat 后异步向服务端创建；用 [getSessionIdentifier] 返非空
  /// 作为「就绪」信号，最多轮询 ~15s（30×500ms）。就绪后写一次 setSessionString/Int。
  /// 永不抛（DD-2），fire-and-forget 不阻塞聊天界面。
  static Future<void> _applySessionDataWhenReady(XbDomainSubscription? sub) async {
    try {
      String? sid;
      for (var i = 0; i < 30; i++) {
        sid = await _safeSessionId();
        if (sid != null && sid.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (sid == null || sid.isEmpty) {
        debugPrint('[CrispSupportService] session 未就绪（~15s），会话数据跳过');
        return;
      }
      // 字段名对齐 Crisp_bot/EZ-Xbaord 格式（大写键，bot _META_FIELDS 消费）。
      _setStr('Source', _sourceLabel); // 来源平台 + 客户端版本（本端附加）。
      if (sub != null) {
        _setStr('Email', sub.email);
        _setStr('Plan', sub.planName ?? '未订阅套餐');
        _setStr('Expires', _expiresText(sub));
        _setStr('Traffic', '${_remainingGb(sub)} GB');
      }
    } catch (e, s) {
      debugPrint('[CrispSupportService] apply session data failed: $e\n$s');
    }
  }

  /// 取 session id（永不抛；无 session 返 null）。
  static Future<String?> _safeSessionId() async {
    try {
      return await FlutterCrispChat.getSessionIdentifier();
    } catch (_) {
      return null;
    }
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
  static String get _sourceLabel => '$sourcePlatform(${myClientVersionLabel()})';

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

  static void _setStr(String key, String value) {
    try {
      FlutterCrispChat.setSessionString(key: key, value: value);
    } catch (_) {/* 永不抛 */}
  }
}
