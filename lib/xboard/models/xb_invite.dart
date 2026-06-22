/// 邀请返佣 + 分享好友领域模型（form-a 邀请功能）。
///
/// **零 SDK 类型穿透**（conventions §2.1 / Property 2）：UI / Provider 只见这些客户端类型，
/// 反腐层 `XboardServiceImpl` 负责把 SDK `InviteInfoModel` / `UserModel` / `CommissionDetailModel` /
/// `ShareLinkModel` 映射成本文件类型（cents → yuan 在反腐层换算）。
///
/// 手写不可变类（无 freezed / 无 codegen）：类型简单、无 copyWith / json 需求，避免 build_runner 依赖。
library;

/// 邀请返佣汇总（数据源：SDK `invite.getInviteInfo()` 统计 + `user.getUserInfo()` 余额）。
class XbInviteInfo {
  /// 当前邀请码（null = 尚未生成，UI 进页面自动调 generateInviteCode 生成）。
  final String? code;

  /// 已注册用户数（stat[0]）。
  final int registeredCount;

  /// 确认中佣金（元；stat[2] cents / 100）。3 天后自动确认到账。
  final double pendingYuan;

  /// 累计获得佣金（元；stat[1] cents / 100）。
  final double totalYuan;

  /// 返佣比例（百分比整数，如 20 表示 20%；stat[3]）。
  final int commissionRate;

  /// 佣金余额（元；可提现 / 划转 —— user.commission_balance / 100）。
  final double commissionBalanceYuan;

  /// 账户余额（元；可购买套餐抵扣 —— user.balance / 100）。
  final double accountBalanceYuan;

  const XbInviteInfo({
    required this.code,
    required this.registeredCount,
    required this.pendingYuan,
    required this.totalYuan,
    required this.commissionRate,
    required this.commissionBalanceYuan,
    required this.accountBalanceYuan,
  });

  /// 是否已有邀请码。
  bool get hasCode => code != null && code!.isNotEmpty;
}

/// 单条返佣记录（数据源：SDK `invite.getCommissionDetails()`；只含已发放成功的流水）。
///
/// ⚠️ 后端 `invite/details` 只返回已发放佣金，无逐条状态、无被邀请人账号 —— 故纯流水。
class XbCommissionRecord {
  /// 记录 ID。
  final int id;

  /// 返佣金额（元；get_amount cents / 100）。
  final double getAmountYuan;

  /// 产生时间。
  final DateTime createdAt;

  const XbCommissionRecord({
    required this.id,
    required this.getAmountYuan,
    required this.createdAt,
  });
}

/// 分享落地页地址（数据源：SDK `shareLink.getShareLink()`）。
///
/// 只承载下载落地页地址（主 / 备），不含邀请码 —— 落地页仅引导下载客户端。
class XbShareLink {
  /// 功能开关（false = 后台关闭 / 未配置 → UI 隐藏分享区块 / 显示未配置态）。
  final bool enabled;

  /// 主要分享落地页地址。
  final String primaryUrl;

  /// 备用分享落地页地址（可空）。
  final String backupUrl;

  const XbShareLink({
    required this.enabled,
    required this.primaryUrl,
    required this.backupUrl,
  });

  /// 是否有备用地址。
  bool get hasBackup => backupUrl.isNotEmpty;
}
