import 'dart:async';
import 'package:fl_clash/xboard/models/tutorial_package.dart';
import 'package:fl_clash/xboard/services/xb_update_probe.dart';
import 'package:fl_clash/xboard/util/tutorial_html.dart';
import 'package:fl_clash/xboard/widgets/tutorial_download_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:html/parser.dart' as html;
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Probe extends Mock implements XbUpdateSourceProbe {}

void main() {
  testWidgets('return fills the footer while probing and dismisses without a late launch', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 720);
    addTearDown(t.view.reset);
    final probe = _Probe();
    final done = Completer<List<String>>();
    const url = 'https://files.example/app.apk';
    when(() => probe.run(any())).thenAnswer((_) => done.future);
    final opened = <Uri>[];
    await t.pumpWidget(ProviderScope(overrides: [
      tutorialManifestProvider.overrideWithValue((_) async => const AppUpdateModel(
        versionCode: 1, versionName: '1', region: 'cn',
        downloads: [AppDownload(url: url, region: 'cn')], sha256: '', changelog: '', force: false)),
      xbUpdateSourceProbeFactoryProvider.overrideWithValue(() => probe),
      tutorialLaunchProvider.overrideWithValue((url) async { opened.add(url); return true; }),
    ], child: MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () => showDialog<void>(context: context, builder: (_) =>
          TutorialDownloadDialog(package: TutorialPackage.android64, ownerActive: () => true)),
      child: const Text('教程原文'))))));
    await t.tap(find.text('教程原文')); await t.pump(); await t.pump(const Duration(milliseconds: 300));
    final back = find.widgetWithText(OutlinedButton, '返回教程');
    expect(t.getRect(back).width, closeTo(t.getRect(find.byType(LinearProgressIndicator)).width, 1));
    await t.tap(back); await t.pumpAndSettle();
    verify(() => probe.cancel()).called(1);
    done.complete([url]); await t.pump();
    expect(opened, isEmpty);
    expect(find.text('教程原文').hitTestable(), findsOneWidget);
  });
  test('all 11 original links keep their content, order and parent; ordinary links still resolve', () {
    final body = [for (final p in TutorialPackage.values)
      '<p><a data-client-download="${p.platform}" ${p.platform == 'android' ? 'data-apk-download="${p.abi}"' : 'data-download-slot="${p.slot}"'} href="downloads/old"><b>${p.label}</b></a></p>'].join();
    final doc = html.parse(buildTutorialHtml('$body<a href="guide">说明</a>', resourceBase: Uri.parse('https://example.org/'), isDark:false));
    final links = doc.querySelectorAll('a');
    expect(links, hasLength(12));
    for (final (i,p) in TutorialPackage.values.indexed) {
      expect(links[i].parent!.localName,'p');
      expect(links[i].querySelector('b')!.text,p.label);
      expect(links[i].attributes['href'],'${TutorialPackage.linkPrefix}${p.slot}');
    }
    expect(links.last.attributes['href'],'https://example.org/guide');
  });
  for (final mode in ['auto','manual','wrong-format','unpublished','retry']) {
    testWidgets('DEB download: $mode', (t) async {
      const url='https://files.example/linux.deb';
      final probe=_Probe();
      when(()=>probe.run(any())).thenAnswer((_) async=>[url]);
      when(()=>probe.hasConfirmedSource).thenReturn(mode=='auto');
      final opened=<Uri>[]; var calls=0;
      await t.pumpWidget(ProviderScope(overrides:[
        tutorialManifestProvider.overrideWithValue((p) async {
          expect((p.platform,p.abi,p.format),('linux','x64','deb'));
          calls++;
          if(mode=='unpublished') return null;
          if(mode=='retry' && calls==1) throw Exception('fixture');
          return AppUpdateModel(versionCode:1,versionName:'1',region:'cn',downloads:[
            if(mode!='wrong-format') const AppDownload(url:url,region:'cn'),
            const AppDownload(url:'https://files.example/linux.AppImage',region:'overseas'),
          ],sha256:'',changelog:'',force:false);
        }),
        xbUpdateSourceProbeFactoryProvider.overrideWithValue(()=>probe),
        tutorialLaunchProvider.overrideWithValue((uri) async {opened.add(uri);return true;}),
      ],child:MaterialApp(home:TutorialDownloadDialog(package:TutorialPackage.debX64,ownerActive:()=>true))));
      await t.pumpAndSettle();
      if(mode=='retry'){await t.tap(find.text('重新获取'));await t.pumpAndSettle();expect(calls,2);}
      if(mode=='wrong-format'||mode=='unpublished') {
        expect(find.text('当前安装包暂无下载。'),findsOneWidget);expect(opened,isEmpty);
      } else {
        if(mode!='auto'){expect(opened,isEmpty);await t.tap(find.text('线路 1'));await t.pumpAndSettle();}
        expect(opened,[Uri.parse(url)]);
        expect(t.getSize(find.widgetWithText(FilledButton, '打开下载链接')),
            t.getSize(find.widgetWithText(OutlinedButton, '返回教程')));
      }
    });
  }
}
