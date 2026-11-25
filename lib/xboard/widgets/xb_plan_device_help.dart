import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:material_ui/material_ui.dart';

import 'xb_theme.dart';
import 'xb_html_contrast.dart';
import 'xb_ui_kit.dart' show XbGradientAction;

const deviceHelpTag = 'xb-device-help';

/// Decorate the rendered copy, not the panel's stored HTML. Recognize a field
/// label, not a mention of devices in the notes. Preserve nested inline styles.
String withPlanDeviceHelp(String source) {
  if (!source.contains('设备')) return source;
  final doc = html.parseFragment(source);
  final chunks = <List<dom.Text>>[];
  var line = <dom.Text>[];
  void endLine() {
    if (line.any((t) => t.data.trim().isNotEmpty)) chunks.add(line);
    line = [];
  }

  const blocks = {
    'p',
    'div',
    'li',
    'tr',
    'dl',
    'dt',
    'dd',
    'section',
    'h1',
    'h2',
    'h3',
    'h4',
  };
  void visit(dom.Node node) {
    if (node is dom.Text) {
      line.add(node);
      return;
    }
    if (node is dom.Element) {
      if (node.localName == 'br') {
        endLine();
        return;
      }
      if (node.localName == 'style' || node.localName == 'script') return;
    }
    final block = node is dom.Element && blocks.contains(node.localName);
    if (block) endLine();
    for (final child in node.nodes) {
      visit(child);
    }
    if (block) endLine();
  }

  visit(doc);
  endLine();
  String text(int i) => chunks[i].map((n) => n.data).join().trim();
  final label = RegExp(r'^[\s💻📱🖥️]*设备(?:数量|限制)?[\s：:]*', unicode: true);
  for (var i = 0; i < chunks.length; i++) {
    final match = label.firstMatch(text(i));
    if (match == null) continue;
    if (match.end == text(i).length &&
        i + 1 < chunks.length &&
        RegExp(r'台|设备|同时使用').hasMatch(text(i + 1))) {
      i++;
    }
    dom.Node last = chunks[i].lastWhere((n) => n.data.trim().isNotEmpty);
    while (last.parentNode is dom.Element &&
        !blocks.contains((last.parentNode as dom.Element).localName) &&
        identical(last.parentNode!.nodes.last, last)) {
      last = last.parentNode!;
    }
    final siblings = last.parentNode!.nodes;
    siblings.insert(siblings.indexOf(last) + 1, dom.Element.tag(deviceHelpTag));
    return doc.outerHtml;
  }
  return source;
}

class XbPlanDeviceHelp extends StatelessWidget {
  const XbPlanDeviceHelp({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '查看设备使用与共享说明',
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    icon: Icon(
      Icons.help_outline_rounded,
      size: 17,
      color: xbReadableHtmlColor(Theme.of(context).colorScheme.primary, XbTokens.of(context).card),
    ),
    onPressed: () => xbShowDialog<void>(
      context: context,
      brandColor: Theme.of(context).colorScheme.primary,
      builder: (_) => const _DeviceHelpDialog(),
    ),
  );
}

class _DeviceHelpDialog extends StatelessWidget {
  const _DeviceHelpDialog();
  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final rules = [
      (Icons.devices, '个人多设备连接', '支持个人名下手机、电脑、平板等终端合理使用。', false),
      (Icons.wifi, '家庭及局域网共享', '支持同住家庭成员或小范围同一 Wi-Fi 环境下日常使用。', false),
      (Icons.block, '公开传播与倒卖', '严禁在社交网络、论坛公开订阅链接或节点，严禁分享给他人使用或转租给他人。', true),
    ];
    return AlertDialog(
      scrollable: true,
      backgroundColor: t.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      title: const Text('设备使用与共享说明', textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: t.sfc,
                borderRadius: BorderRadius.circular(XbTokens.rMd),
              ),
              child: Column(
                children: [
                  for (final rule in rules) ...[
                    if (rule != rules.first) Divider(height: 1, color: t.line),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            rule.$1,
                            size: 20,
                            color: rule.$4 ? XbTokens.bad : t.onOk,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        rule.$2,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      rule.$4 ? '严禁' : '支持',
                                      style: TextStyle(
                                        color: rule.$4 ? XbTokens.bad : t.onOk,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  rule.$3,
                                  style: TextStyle(
                                    color: t.onv,
                                    fontSize: 13,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '请保护好订阅链接，个人及家庭日常共享请勿公开传播。',
              style: TextStyle(color: t.onv, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: XbGradientAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了'),
          ),
        ),
      ],
    );
  }
}
