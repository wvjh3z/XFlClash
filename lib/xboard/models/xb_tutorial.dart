/// 使用教程领域模型（form-a 使用教程功能）。
///
/// **零 SDK 类型穿透**（conventions §2.1）：UI / Provider 只见这些客户端类型，
/// 反腐层 `XboardServiceImpl` 负责把 SDK `KnowledgeItem` / `KnowledgeArticle` 映射成本文件类型
/// （并按「官方客户端」分类过滤、Unix 秒 → DateTime 换算）。
///
/// 手写不可变类（无 freezed / 无 codegen）：类型简单、无 copyWith / json 需求。
library;

/// 教程列表项（数据源：SDK `knowledge.getKnowledgeList()` 过滤「官方客户端」分类）。
class XbTutorial {
  /// 文章 ID（详情按此拉取）。
  final int id;

  /// 标题。
  final String title;

  /// 最后更新时间。
  final DateTime updatedAt;

  const XbTutorial({
    required this.id,
    required this.title,
    required this.updatedAt,
  });
}

/// 教程详情（含正文；数据源：SDK `knowledge.getKnowledgeDetail(id)`）。
class XbTutorialDetail {
  /// 文章 ID。
  final int id;

  /// 标题。
  final String title;

  /// 正文（后端 HTML / Markdown 文本）。
  final String body;

  /// 最后更新时间。
  final DateTime updatedAt;

  const XbTutorialDetail({
    required this.id,
    required this.title,
    required this.body,
    required this.updatedAt,
  });
}
