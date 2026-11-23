import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_state_provider.dart';
import '../../providers/xboard_providers.dart';

/// This action probes guest config only; it never repeats the form submission.
class AuthNetworkHint extends ConsumerStatefulWidget {
  const AuthNetworkHint({super.key});
  @override
  ConsumerState<AuthNetworkHint> createState() => _AuthNetworkHintState();
}

class _AuthNetworkHintState extends ConsumerState<AuthNetworkHint> {
  bool _busy = false;
  String? _message;
  Future<void> _check() async {
    if (_busy) return;
    final race = ref.read(injectedRaceControllerProvider);
    final route = ModalRoute.of(context);
    final auth = ref.read(authStateProvider.notifier);
    final revision = auth.sessionRevision;
    bool current() => mounted && route?.isCurrent == true && auth.sessionRevision == revision &&
        identical(ref.read(injectedRaceControllerProvider), race);
    setState(() => _busy = true);
    final found = await race?.recheckApi(current: current);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (current()) _message = found == true ? '线路可用，请先核对上次操作结果。' : '暂未找到可用线路，请稍后重试。';
    });
  }
  @override
  Widget build(BuildContext context) => Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
    if (_message != null) Text(_message!),
    TextButton(onPressed: _busy ? null : _check, child: Text(_busy ? '检测中…' : '重新检测线路')),
  ]);
}
