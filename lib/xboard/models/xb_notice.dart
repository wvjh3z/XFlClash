/// 公告领域模型（form-a 首页公告；SDK NoticeModel → 反腐层裁剪）。
///
/// **零 SDK 类型穿透**（conventions §2.1 / Property 2）：UI / Provider 只见本类型，反腐层
/// `XboardServiceImpl` 负责把 SDK `NoticeModel` 映射过来（已过滤 `show==true`）。
///
/// 手写不可变类（无 freezed / 无 codegen）：类型简单，避免 build_runner 依赖（同 xb_invite.dart）。
library;

class XbNotice {
  /// 公告 id（已读判定主键）。
  final int id;

  /// 标题。
  final String title;

  /// 正文（后端富文本编辑器存的 HTML；客户端经 flutter_html 渲染）。
  final String content;

  /// 创建时间（展示用）。
  final DateTime createdAt;

  /// 更新时间（Unix 秒）—— 已读判定用：`updatedAt > 已读记录` 即视为"被编辑过的新内容"。
  final int updatedAt;

  const XbNotice({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });
}
