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
/// **复用边界**：本服务是 ◇ Xboard 自有代码（不经 FlClash adapter，无风险②）。
/// 已登录时把账号 email 透传给 Crisp（关联会话与工单）；游客不传（匿名会话）。
///
/// **永不抛**（与 DD-2 一致）：平台调用失败（如桌面缺 WebKitGTK / 测试环境无插件）
/// 全捕获，仅 debugPrint，不让客服入口崩溃波及「我的」页。
library;

import 'package:crisp_chat/crisp_chat.dart';
import 'package:flutter/foundation.dart';

import '../config/xboard_config.dart';

/// Crisp 在线客服服务（静态封装，无状态）。
class CrispSupportService {
  CrispSupportService._();

  /// 当前 flavor 是否配置了 Crisp websiteId（决定「帮助与客服」入口是否显示）。
  static bool get isEnabled =>
      XboardConfig.current.crispWebsiteId.trim().isNotEmpty;

  /// 打开 Crisp 客服会话。
  ///
  /// [email] 已登录账号邮箱（从 `userProfileProvider` 取，关联会话）；游客传 null（匿名）。
  /// 永不抛：平台异常全捕获（DD-2）。返回是否成功发起（失败 = false，调用方可 toast 兜底）。
  static Future<bool> open({String? email}) async {
    final websiteId = XboardConfig.current.crispWebsiteId.trim();
    if (websiteId.isEmpty) return false; // 未配置（入口本应已隐藏，双重防御）。
    try {
      final user = (email != null && email.trim().isNotEmpty)
          ? User(email: email.trim())
          : null;
      final config = CrispConfig(
        websiteID: websiteId,
        user: user,
        // 推送第一版不接（mobile FCM/APNs 未配置）→ 关掉避免 SDK 尝试注册。
        enableNotifications: false,
      );
      await FlutterCrispChat.openCrispChat(config: config);
      return true;
    } catch (e, s) {
      debugPrint('[CrispSupportService] open failed: $e\n$s');
      return false;
    }
  }
}
