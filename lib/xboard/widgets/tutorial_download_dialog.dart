import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/tutorial_package.dart';
import '../providers/xboard_providers.dart';
import '../services/xb_update_probe.dart';
import '../services/xb_update_sources.dart';

final tutorialManifestProvider = Provider<Future<AppUpdateModel?> Function(TutorialPackage)>((ref) {
  final sdk = ref.watch(xboardSdkProvider);
  return (package) async {
    if (sdk == null) throw StateError('Version service not ready');
    return sdk.appUpdate.checkUpdate(platform: package.platform, abi: package.abi,
        currentVersionCode: 0, format: package.format);
  };
});
final tutorialLaunchProvider = Provider<Future<bool> Function(Uri)>((_) =>
    (uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

enum _Phase { fetching, checking, unavailable, failed, manual, opened }

class TutorialDownloadDialog extends ConsumerStatefulWidget {
  const TutorialDownloadDialog({super.key, required this.package, required this.ownerActive});
  final TutorialPackage? package;
  final bool Function() ownerActive;
  @override
  ConsumerState<TutorialDownloadDialog> createState() => _DownloadState();
}

class _DownloadState extends ConsumerState<TutorialDownloadDialog> {
  _Phase phase = _Phase.fetching;
  XbUpdateSourceProbe? probe;
  Map<String,String> mirrors = {};
  String? opened;
  bool launching = false;
  bool get active => mounted && widget.ownerActive() && ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (active) unawaited(load()); });
  }
  @override
  void dispose() { probe?.cancel(); super.dispose(); }

  Future<void> load() async {
    setState(() { phase = _Phase.fetching; mirrors = {}; });
    final package = widget.package;
    if (package == null) { setState(() => phase = _Phase.unavailable); return; }
    try {
      final info = await ref.read(tutorialManifestProvider)(package).timeout(const Duration(seconds: 15));
      if (!active) return;
      final urls = info == null ? <String>[] : xbSortedUpdateUrls(info).where(package.accepts).toSet().toList();
      if (info == null || urls.isEmpty) { setState(() => phase = _Phase.unavailable); return; }
      mirrors = {for (final m in info.downloads) if (urls.contains(m.url.trim())) m.url.trim(): m.region};
      setState(() => phase = _Phase.checking);
      final round = probe = ref.read(xbUpdateSourceProbeFactoryProvider)();
      final ordered = await round.run(urls);
      if (!active) return;
      if (round.hasConfirmedSource && ordered.isNotEmpty) { await open(ordered.first); }
      else { setState(() => phase = _Phase.manual); }
    } catch (_) { if (active) setState(() => phase = _Phase.failed); }
  }

  Future<void> open(String url) async {
    if (!active || launching || !mirrors.containsKey(url)) return;
    setState(() => launching = true);
    var ok = false;
    try { ok = await ref.read(tutorialLaunchProvider)(Uri.parse(url)); } catch (_) { /* show manual choices */ }
    if (active) setState(() { launching = false; opened = ok ? url : null; phase = ok ? _Phase.opened : _Phase.manual; });
  }

  @override
  Widget build(BuildContext context) {
    final waiting = phase == _Phase.fetching || phase == _Phase.checking;
    return AlertDialog(scrollable: true, title: const Text('客户端下载'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.package case final package?) Text(package.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Text(switch (phase) {
          _Phase.fetching => '正在获取下载线路…', _Phase.checking => '正在检测下载线路…',
          _Phase.failed => '读取下载线路失败，请重试。', _Phase.unavailable => '当前安装包暂无下载。',
          _Phase.manual => '自动下载未完成，请选择一条线路下载。', _Phase.opened => '已打开下载链接。如果下载没有开始，可以再次打开。',
        }),
        if (waiting) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (phase == _Phase.manual) for (final group in ['cn', 'overseas', 'unknown'])
          if (mirrors.values.any((r) => _group(r) == group)) ...[
            const SizedBox(height: 12), Text(switch (group) { 'cn' => '国内线路', 'overseas' => '海外线路', _ => '备用线路' }),
            Wrap(spacing: 6, children: [for (final (i, entry) in mirrors.entries.where((e) => _group(e.value) == group).indexed)
              OutlinedButton(onPressed: launching ? null : () => open(entry.key), child: Text('线路 ${i+1}'))]),
          ],
      ]), actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回教程')),
        if (phase == _Phase.failed) FilledButton(onPressed: load, child: const Text('重新获取')),
        if (phase == _Phase.opened) FilledButton(onPressed: launching ? null : () => open(opened!), child: const Text('打开下载链接'))]);
  }
  String _group(String region) => region == 'cn' || region == 'overseas' ? region : 'unknown';
}
