import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:fl_clash/xboard/services/exit_ip_probe.dart';
import 'package:fl_clash/xboard/services/xb_update_region.dart';
import 'package:fl_clash/xboard/services/xb_update_sources.dart';

class PendingProbe extends XbExitIpProbe {
  final answer = Completer<XbExitIpResult?>();
  int cancelled = 0;
  @override
  Future<XbExitIpResult?> run() => answer.future;
  @override
  void cancel() {
    cancelled++;
    super.cancel();
  }
}

AppUpdateModel model(String region) => AppUpdateModel(
  versionCode: 36,
  versionName: '0.0.1',
  region: region,
  sha256: '',
  changelog: '',
  force: false,
  downloads: const [
    AppDownload(url: 'https://cn1.example/a', region: 'cn'),
    AppDownload(url: 'https://cn2.example/a', region: 'cn'),
    AppDownload(url: 'https://os1.example/a', region: 'overseas'),
    AppDownload(url: 'https://os2.example/a', region: 'overseas'),
    AppDownload(url: 'https://cn1.example/a', region: 'overseas'),
    AppDownload(url: 'javascript:bad', region: 'cn'),
  ],
);
void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    test('$brand country overrides server and groups stay separate', () {
      for (final country in ['CN', 'US']) {
        final starts = <String>{};
        for (var seed = 0; seed < 32; seed++) {
          final urls = xbRandomizedUpdateUrls(
            model('cn'),
            countryCode: country,
            random: Random(seed),
          );
          expect(urls.length, 4);
          expect(urls.toSet().length, 4);
          expect(
            urls
                .take(2)
                .every((u) => u.contains(country == 'CN' ? '//cn' : '//os')),
            isTrue,
          );
          starts.add(urls.first);
        }
        expect(starts.length, 2);
      }
    });
    test('$brand fallback and unknown preserve source model', () {
      final info = model('unknown');
      final urls = xbRandomizedUpdateUrls(info, random: Random(3));
      expect(urls, [
        'https://cn1.example/a',
        'https://cn2.example/a',
        'https://os1.example/a',
        'https://os2.example/a',
      ]);
      expect(info.downloads.length, 6);
      expect(
        xbRandomizedUpdateUrls(model('overseas'), random: Random(2)).first,
        startsWith('https://os'),
      );
    });
    test(
      '$brand browser consumes frozen order and continues after failure',
      () async {
        final urls = xbRandomizedUpdateUrls(model('cn'), random: Random(2));
        final attempted = <String>[];
        expect(
          await xbOpenUpdateDownload(
            model('overseas'),
            orderedUrls: urls,
            open: (uri) async {
              attempted.add('$uri');
              return attempted.length == 3;
            },
          ),
          isTrue,
        );
        expect(attempted, urls.take(3));
      },
    );
  }
  testWidgets(
    'whole lookup deadline cancels, late reply cannot replace fallback',
    (tester) async {
      final probe = PendingProbe();
      final lookup = XbUpdateRegionLookup(probe: probe);
      String? result = 'waiting';
      final future = lookup.run().then((value) => result = value);
      await tester.pump(const Duration(seconds: 3));
      await future;
      expect(result, isNull);
      expect(probe.cancelled, 1);
      probe.answer.complete(const XbExitIpResult('1.2.3.4', 'CN'));
      await tester.pump();
      expect(result, isNull);
    },
  );
  test('dispose cancellation rejects late result', () async {
    final probe = PendingProbe();
    final lookup = XbUpdateRegionLookup(probe: probe);
    final result = lookup.run();
    lookup.cancel();
    probe.answer.complete(const XbExitIpResult('1.2.3.4', 'US'));
    expect(await result, isNull);
  });
}
