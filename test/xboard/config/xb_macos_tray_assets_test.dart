import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/common/tray.dart';
import '../../../tool/system_icon_assets.dart';

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    test(
      '$brand macOS runtime paths have injected bytes for every state and density',
      () async {
        final assets = await loadSystemIconAssets(
          projectRoot: Directory.current.path,
          flavor: brand,
        );
        final writes = desktopSystemIconWrites(assets, platform: 'macos');
        final tray = AppTray.forPlatform(isMacOS: true, isWindows: false);
        final root = Directory.systemTemp.createTempSync('brand-macos-icons-');
        addTearDown(() => root.deleteSync(recursive: true));
        applySystemIconWrites(projectRoot: root.path, writes: writes);
        for (final monochrome in [true, false]) {
          for (final state in [
            (false, false, false),
            (true, false, false),
            (true, true, false),
            (true, true, true),
          ]) {
            final path = tray.getTrayIcon(
              isStart: state.$1,
              tunEnable: state.$2,
              safeMode: state.$3,
              monochrome: monochrome,
            );
            final split = path.lastIndexOf('/');
            final name = path
                .substring(split + 1)
                .replaceFirst('status_4', 'status_1');
            final expected =
                assets.files['${monochrome ? 'macos' : 'linux'}/$name']!;
            for (final scale in ['', '2.0x/', '3.0x/', '4.0x/']) {
              final scaled =
                  '${path.substring(0, split + 1)}$scale${path.substring(split + 1)}';
              expect(writes, contains(scaled));
              expect(
                File('${root.path}/$scaled').readAsBytesSync(),
                orderedEquals(expected),
              );
            }
          }
        }
      },
    );
  }
}
