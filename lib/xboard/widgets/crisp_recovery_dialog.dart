import 'package:material_ui/material_ui.dart';
import '../services/crisp_chat_driver.dart';

enum CrispRecovery { retry, browser, runtime }

class CrispRecoveryDialog extends StatelessWidget {
  const CrispRecoveryDialog({super.key, required this.failure});
  final CrispChatFailure? failure;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      failure == CrispChatFailure.webView2Unavailable
          ? '需要安装客服运行组件'
          : '在线客服暂时不可用',
    ),
    content: Text(
      '${crispFailureMessage(failure)}\n\n也可以在浏览器中联系客服；浏览器的聊天记录和账号资料不会自动与应用同步。',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      if (failure == CrispChatFailure.webView2Unavailable)
        TextButton(
          onPressed: () => Navigator.pop(context, CrispRecovery.runtime),
          child: const Text('前往下载'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context, CrispRecovery.browser),
        child: const Text('浏览器打开'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, CrispRecovery.retry),
        child: const Text('重试'),
      ),
    ],
  );
}

String crispFailureMessage(CrispChatFailure? failure) => switch (failure) {
  CrispChatFailure.webView2Unavailable =>
    '在线客服需要 Microsoft Edge WebView2 Runtime。可以安装运行组件后重试，或直接使用浏览器。',
  CrispChatFailure.webViewUnavailable => '当前系统的客服组件不可用，请检查应用安装是否完整',
  CrispChatFailure.profileUnavailable => '客服数据无法保存，请检查应用的存储权限或可用空间后重试',
  CrispChatFailure.startupFailed => '客服窗口无法启动，请重试',
  CrispChatFailure.startupTimeout => '客服启动时间较长，请稍后重试',
  CrispChatFailure.sessionNotReady => '客服加载失败，请检查网络后重试',
  CrispChatFailure.sessionDataFailed => '客服账号资料未能同步，请稍后重新打开客服',
  CrispChatFailure.resetFailed => '客服会话未能重置，请重新打开应用后再试',
  CrispChatFailure.closeFailed => '上一次客服窗口未能关闭，请关闭窗口后重试',
  _ => '客服暂时无法打开，请稍后再试',
};
