import 'package:fl_clash/xboard/services/tutorial_webview_environment.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart'
    show InternalChannelController;
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const factoryChannel = MethodChannel(
    'com.pichillilorenzo/flutter_webview_environment',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> created;
  late List<String> disposed;
  late List<WindowsWebViewEnvironment> platforms;

  setUp(() {
    created = [];
    disposed = [];
    platforms = [];
    messenger.setMockMethodCallHandler(factoryChannel, (call) async {
      expect(call.method, 'create');
      final id = (call.arguments as Map)['id'] as String;
      created.add(id);
      // The native plugin registers one channel under the requested ID.
      messenger.setMockMethodCallHandler(
        MethodChannel('com.pichillilorenzo/flutter_webview_environment_$id'),
        (call) async {
          expect(call.method, 'dispose');
          disposed.add(id);
          return null;
        },
      );
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(factoryChannel, null);
    for (final id in created) {
      messenger.setMockMethodCallHandler(
        MethodChannel('com.pichillilorenzo/flutter_webview_environment_$id'),
        null,
      );
    }
    for (final platform in platforms) {
      if (!platform.disposed) platform.disposeChannel();
    }
  });

  Future<WebViewEnvironment> createEnvironment() async {
    final platform = await WindowsWebViewEnvironment.static().create();
    platforms.add(platform);
    return WebViewEnvironment.fromPlatform(platform: platform);
  }

  test(
    'pinned Windows factory binds the unpatched disposal to the wrong ID',
    () async {
      final environment = await createEnvironment();
      expect(
        (environment.platform as WindowsWebViewEnvironment).channel!.name,
        isNot(
          'com.pichillilorenzo/flutter_webview_environment_${environment.id}',
        ),
      );
      await expectLater(
        environment.dispose(),
        throwsA(isA<MissingPluginException>()),
      );
      expect(disposed, isEmpty);
    },
  );

  test(
    'repair makes public disposal target the native environment ID',
    () async {
      final environment = await createEnvironment();
      repairTutorialWebViewEnvironment(environment);
      await environment.dispose();
      expect(disposed, [environment.id]);
      expect(
        (environment.platform as WindowsWebViewEnvironment).disposed,
        isTrue,
      );
    },
  );

  test('repair isolates two environments and is idempotent', () async {
    final first = await createEnvironment();
    final second = await createEnvironment();
    repairTutorialWebViewEnvironment(first);
    repairTutorialWebViewEnvironment(second);
    repairTutorialWebViewEnvironment(first);
    await second.dispose();
    expect(disposed, [second.id]);
    expect((first.platform as WindowsWebViewEnvironment).disposed, isFalse);
    await first.dispose();
    expect(disposed, [second.id, first.id]);
    // A late cleanup must not resurrect an already disposed environment.
    repairTutorialWebViewEnvironment(first);
    expect((first.platform as WindowsWebViewEnvironment).disposed, isTrue);
  });
}
