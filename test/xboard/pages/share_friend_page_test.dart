import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/pages/share_friend_page.dart';
import 'package:fl_clash/xboard/providers/share_link_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('恢复只重查失败的分享链接；刷新出错仍保留同账号旧链接', (tester) async {
    var reads = 0;
    final container = ProviderContainer(overrides: [
      shareLinkProvider.overrideWith((_) async {
        if (++reads != 2) throw const XbNetwork(XbNetworkKind.timeout, 'offline');
        return const XbShareLink(enabled: true, primaryUrl: 'https://download.example/', backupUrl: '');
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: ShareFriendPage())));
    await tester.pumpAndSettle();
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(find.text('主要地址'), findsOneWidget);
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(reads, 2);
    container.invalidate(shareLinkProvider);
    await tester.pumpAndSettle();
    expect(find.textContaining('当前显示上次数据'), findsOneWidget);
    expect(find.text('主要地址'), findsOneWidget);
  });
  testWidgets('手机未配置分享地址时可直接下拉刷新出新地址', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        shareLinkProvider.overrideWith((ref) async {
          calls++;
          return XbShareLink(
            enabled: calls > 1,
            primaryUrl: calls > 1 ? 'https://download.example/' : '',
            backupUrl: '',
          );
        }),
      ],
      child: const MaterialApp(home: ShareFriendPage()),
    ));
    await tester.pumpAndSettle();
    final title = find.text('暂无分享地址');
    expect(tester.getCenter(title).dy, lessThan(844 / 3));
    expect(find.text('主要地址'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 420));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(title, findsNothing);
    expect(find.text('主要地址'), findsOneWidget);
    expect(find.text('备用地址'), findsNothing);
  });
}
