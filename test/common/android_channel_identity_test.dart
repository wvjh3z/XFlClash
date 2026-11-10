import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/battery.dart';
import 'package:fl_clash/plugins/tile.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/protocol.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _TileProbe with TileListener {
  bool started = false;
  @override
  void onStart() => started = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('brand identity cannot change the engine-local service protocol', () async {
    const brand = String.fromEnvironment('XB_NATIVE_ID', defaultValue: 'com.follow.clash');
    expect(nativePackageName, brand);
    expect(packageName, 'com.follow.clash');
    const channel = MethodChannel('com.follow.clash/service');
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return '';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await Service().init(), '');
    expect(calls, ['init']);
    final components = File('android/common/src/main/java/com/follow/clash/common/Components.kt').readAsStringSync();
    expect(components, contains('const val PACKAGE_NAME = "$packageName"'));
    for (final plugin in ['Service', 'App', 'Battery', 'Tile']) {
      final source = File('android/app/src/main/kotlin/com/follow/clash/plugins/${plugin}Plugin.kt').readAsStringSync();
      expect(source, contains('Components.PACKAGE_NAME'));
    }
  });
  test('core, app and battery calls use the native protocol names', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    final corePayloads = <Map<String, dynamic>>[];
    for (final suffix in ['core', 'app', 'battery']) {
      final channel = MethodChannel('com.follow.clash/$suffix');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add('$suffix/${call.method}');
        if (suffix == 'core') {
          corePayloads.add(jsonDecode(call.arguments as String) as Map<String, dynamic>);
          return Uint8List.fromList(utf8.encode(jsonEncode({'result': true})));
        }
        return suffix == 'app' ? true : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final response = await Service().invokeMethod(
      const CoreMethodCall(method: CoreMethod.coreInitialized),
    );
    expect(response.result, isTrue);
    expect(corePayloads, [
      {'method': 'core.initialized', 'arguments': null},
    ]);
    expect(await App().moveTaskToBack(), true);
    await BatteryOptimization.instance.requestIgnore();
    expect(calls, ['core/invokeMethod', 'app/moveTaskToBack', 'battery/requestIgnoreOptimizations']);
  });
  test('native tile event reaches the brand app listener', () async {
    final probe = _TileProbe();
    Tile.instance.addListener(probe);
    addTearDown(() => Tile.instance.removeListener(probe));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'com.follow.clash/tile',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('start')),
      (_) {},
    );
    expect(probe.started, true);
  });
  test('Linux protocol handler retains the selected brand identity', () {
    const scheme = String.fromEnvironment('XB_URL_SCHEME');
    const plan = LinuxProtocolRegistrationPlan(schemes: protocolSchemes,
        executable: '/tmp/app', applicationsDir: '/tmp/apps');
    expect(plan.desktopId, scheme.isEmpty ? 'flclash-url-handler.desktop' : '$nativePackageName-url-handler.desktop');
  });
}
