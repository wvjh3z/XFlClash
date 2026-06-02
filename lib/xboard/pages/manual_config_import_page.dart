/// R4.8 手动导入配置页（终极救援通道）。
///
/// 当所有自动恢复路径失效（bootstrapUrls 全挂 + R4.7 自举地址也挂 + 缓存/fallback 全失效），
/// 用户经外部渠道（客服 / 官网 / 社群）拿到应急 config 密文，在此粘贴导入。
/// 导入成功 → 写本地缓存 → 提示重启 App 生效。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../services/bootstrap_decryptor.dart';
import '../services/bootstrap_local_loader.dart';
import '../services/bootstrap_manual_import.dart';
import '../widgets/xb_ui_kit.dart';

class ManualConfigImportPage extends ConsumerStatefulWidget {
  const ManualConfigImportPage({super.key});

  @override
  ConsumerState<ManualConfigImportPage> createState() =>
      _ManualConfigImportPageState();
}

class _ManualConfigImportPageState
    extends ConsumerState<ManualConfigImportPage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _done = false;
  int _apiCount = 0;
  int _subCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  BootstrapManualImport _service() {
    final decryptor =
        BootstrapDecryptor(aesKey: XboardConfig.current.bootstrapAesKeyBytes);
    return BootstrapManualImport(
      decryptor: decryptor,
      loader: BootstrapLocalLoader(decryptor: decryptor),
    );
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _service().importFromText(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _done = true;
        _apiCount = result.apiCount;
        _subCount = result.subCount;
      } else {
        _error = switch (result.failure!) {
          ManualImportFailure.empty => '请先粘贴配置内容',
          ManualImportFailure.malformedInput => '配置格式不正确，请确认复制完整',
          ManualImportFailure.decryptFailed => '配置无法解密，可能已损坏或与当前版本不匹配',
        };
      }
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _controller.text = text;
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(builder: _buildScaffold),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('手动导入配置')),
      body: _done ? _successView(context) : _formView(context),
    );
  }

  Widget _formView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '仅在无法连接服务器时使用。请向客服获取应急配置，'
                  '粘贴到下方导入。导入后需重启 App 生效。',
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          enabled: !_busy,
          minLines: 6,
          maxLines: 12,
          decoration: InputDecoration(
            hintText: '粘贴应急配置内容（以 { 开头的一段文本）',
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            errorText: _error,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _pasteFromClipboard,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('从剪贴板粘贴'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _import,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: Colors.white))
              : const Icon(Icons.download_done_rounded),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            minimumSize: const Size.fromHeight(50),
          ),
          label: const Text('导入配置'),
        ),
      ],
    );
  }

  Widget _successView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('配置导入成功',
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('已导入 $_apiCount 个接口线路、$_subCount 个订阅线路。\n请重启 App 使配置生效。',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
