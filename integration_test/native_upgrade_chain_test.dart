/// Local Linux acceptance for the v0.9.1 upgrade. Uses real Flutter plugins,
/// SDK HTTP, encrypted subscriptions, SQLite, Rust IPC and the Go core.
/// All account data is a loopback fixture; system proxy/TUN/DNS changes are off.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/preferences_store.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/main.dart' as application;
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/sheets/login_sheet.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';
import 'package:fl_clash/xboard/xboard_module.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../test/xboard/services/_bootstrap_crypto_helper.dart';

const _node = '本地验收节点';
const _email = 'native-chain@example.invalid';
const _password = 'fixture-password';
const _token = 'native-upgrade-fixture-token';
const _yaml = '''
proxies:
  - {name: "本地验收节点", type: direct}
proxy-groups:
  - {name: "验收线路", type: select, proxies: ["本地验收节点", DIRECT]}
rules:
  - MATCH,验收线路
dns:
  enable: false
''';

// The headless host has no NetworkManager. All SDK/core network I/O below
// remains real; OS connectivity-change notification is outside this fixture.
class _FixtureConnectivity extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.wifi,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value([ConnectivityResult.wifi]);
}

class _Panel {
  late HttpServer server;
  late String encrypted;
  final hits = <String, int>{};
  int authorizedReads = 0;
  String get origin => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    encrypted = await encryptPayloadRaw(_yaml, aad: kEncryptedSubscriptionAad);
    server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      const int.fromEnvironment('XB_FIXTURE_PORT'),
    );
    server.listen((request) async {
      final path = request.uri.path;
      hits.update(path, (n) => n + 1, ifAbsent: () => 1);
      final response = request.response;
      response.headers.contentType = ContentType.json;
      Object body;
      if (path == '/api/v1/passport/auth/login') {
        final raw = await utf8.decoder.bind(request).join();
        final values =
            request.headers.contentType?.mimeType == 'application/json'
            ? jsonDecode(raw) as Map
            : Uri.splitQueryString(raw);
        if (values['email'] != _email || values['password'] != _password) {
          response.statusCode = 400;
          body = {'message': '邮箱或密码错误'};
        } else {
          body = {
            'data': {
              'auth_data': _token,
              'token': 'fixture-sub-token',
              'is_admin': false,
            },
          };
        }
      } else if (path == '/api/v1/user/getSubscribe' ||
          path == '/api/v1/user/info') {
        if (!(request.headers.value('authorization') ?? '').contains(_token)) {
          response.statusCode = 401;
          body = {'message': 'Unauthenticated'};
        } else {
          authorizedReads++;
          body = {
            'data': {
              'email': _email,
              'uuid': '11111111-2222-4333-8444-555555555555',
              'plan_id': 1,
              'plan': {'id': 1, 'name': '本地验收套餐'},
              'u': 1024,
              'd': 2048,
              'transfer_enable': 107374182400,
              'expired_at':
                  DateTime.now()
                      .add(const Duration(days: 30))
                      .millisecondsSinceEpoch ~/
                  1000,
              'subscribe_url': '$origin/sub/fixture-sub-token',
              'reset_day': 15,
            },
          };
        }
      } else if (path == '/sub/encrypted/fixture-sub-token') {
        response.headers.contentType = ContentType.text;
        response.write(encrypted);
        await response.close();
        return;
      } else if (path == '/core-proof') {
        response.headers.contentType = ContentType.text;
        response.write('native-core-forwarded');
        await response.close();
        return;
      } else if (path.contains('/notice/') || path.contains('/order/')) {
        body = {'data': <Object>[]};
      } else if (path.contains('/checkLogin')) {
        body = {
          'data': {'is_login': true},
        };
      } else {
        body = {'data': <String, Object>{}};
      }
      if (body is Map<String, dynamic>) {
        body = {
          'status': response.statusCode < 400 ? 'success' : 'fail',
          ...body,
        };
      }
      response.write(jsonEncode(body));
      await response.close();
    });
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String stage,
) async {
  debugPrint('NATIVE_CHAIN waiting: $stage');
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'Native upgrade stage: $stage');
  debugPrint('NATIVE_CHAIN ready: $stage');
}

Future<void> _listenerState(
  WidgetTester tester,
  int port,
  bool expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (true) {
    var listening = false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      listening = true;
      socket.destroy();
    } on SocketException catch (error) {
      if (error.osError?.errorCode != 111) rethrow; // Linux ECONNREFUSED
    }
    if (listening == expected) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('Core listener did not become ${expected ? "ready" : "closed"}');
    }
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  debugPrint('NATIVE_CHAIN registered');
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'brand startup, login, encrypted profile, nodes, connect and disconnect',
    (tester) async {
      final output = Platform.environment['XB_NATIVE_SMOKE_DIR'];
      debugPrint(
        'NATIVE_CHAIN body entered; isolated-directory-present=${output != null}',
      );
      if (!Platform.isLinux || output == null || !output.startsWith('/')) {
        throw StateError('Run through the isolated local Linux smoke runner.');
      }
      expect(
        Platform.environment['APPIMAGE'],
        isNotEmpty,
        reason:
            'Use the upstream direct launcher, without installing a helper.',
      );
      final directory = Directory(output);
      void stage(String value) {
        debugPrint('NATIVE_CHAIN stage: $value');
        File(
          '${directory.path}/stage.txt',
        ).writeAsStringSync('$value\n', mode: FileMode.append, flush: true);
      }

      stage('before-directory');
      await directory.create(recursive: true);
      final data = Directory('${directory.path}/data');
      await data.create();
      AppPath.supportDirectory = () async => data;
      AppPath.temporaryDirectory = () async => data;
      AppPath.cacheDirectory = () async => data;
      AppPath.downloadDirectory = () async => data;
      expect(
        (await getApplicationDocumentsDirectory()).path,
        '${directory.path}/documents',
        reason: 'The real Xboard index database must be isolated too.',
      );
      stage('before-path');
      await appPath.rebind();
      stage('after-path');
      SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
        appPath.sharedPreferencesPath,
      );
      await preferences.rebind();
      stage('preferences');
      final config = XboardConfig.fromEnvironment();
      expect(config.formA, isTrue);
      expect(config.sentryDsn, isEmpty);
      expect(config.bootstrapAesKeyBytes, testAesKey);
      expect(config.flavorId, anyOf('brand_a', 'brand_b'));
      expect(config.appName, config.flavorId == 'brand_a' ? 'OmoFly' : '袋鼠加速');
      final panel = _Panel();
      await panel.start();
      stage('fixture-server');
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final proxyPort = reserved.port;
      await reserved.close();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('xb_consent_v1', true);
      await prefs.setBool(kXbIpv6DefaultAppliedKey, true);
      expect(
        prefs.containsKey(kBootstrapCacheKey),
        isFalse,
        reason:
            'Startup must use the selected brand fallback bundled by the runner.',
      );
      final icon = await rootBundle.load('assets/images/icon.png');
      expect(
        crypto.sha256
            .convert(
              icon.buffer.asUint8List(icon.offsetInBytes, icon.lengthInBytes),
            )
            .toString(),
        const String.fromEnvironment('XB_FIXTURE_ICON_SHA256'),
      );
      await preferences.setVersion(1);
      await preferences.setUpgradeVersion(2);
      expect(
        await preferences.saveConfig(
          Config(
            themeProps: defaultThemeProps,
            appSettingProps: const AppSettingProps(
              locale: 'zh_CN',
              acceptedDisclaimerVersion: 0,
              autoCheckUpdate: false,
              showTrayTitle: false,
            ),
            networkProps: const NetworkProps(
              systemProxy: false,
              autoSetSystemDns: false,
            ),
            vpnProps: const VpnProps(enable: false, systemProxy: false),
            patchClashConfig: PatchClashConfig(
              mixedPort: proxyPort,
              tun: const Tun(enable: false),
            ),
          ),
        ),
        isTrue,
      );
      final originalErrors = FlutterError.onError;
      final originalErrorBuilder = ErrorWidget.builder;
      final originalConnectivity = ConnectivityPlatform.instance;
      var booted = false;
      addTearDown(() async {
        FlutterError.onError = originalErrors;
        ErrorWidget.builder = originalErrorBuilder;
        ConnectivityPlatform.instance = originalConnectivity;
        await File('${directory.path}/diagnostics.json').writeAsString(
          jsonEncode({
            'http_counts': panel.hits,
            'auth_state': booted
                ? globalState.container.read(authStateProvider).name
                : 'not-booted',
            'visible_text': [
              for (final text in tester.widgetList<Text>(find.byType(Text)))
                text.data ?? text.textSpan?.toPlainText(),
            ],
            'login_labels': [
              for (final text in tester.widgetList<Text>(
                find.descendant(
                  of: find.byType(LoginSheet),
                  matching: find.byType(Text),
                ),
              ))
                text.data ?? text.textSpan?.toPlainText(),
            ],
          }),
        );
        await XboardModule.dispose();
        if (booted) {
          await globalState.container
              .read(setupActionProvider.notifier)
              .setRunning(false);
        }
        await coreController.close();
        await panel.server.close(force: true);
        await singleInstanceLock.release();
        await tester.pumpWidget(const SizedBox.shrink());
        if (booted) globalState.container.dispose();
        await database.close();
      });
      try {
        ConnectivityPlatform.instance = _FixtureConnectivity();
        stage('before-production-main');
        application.main(const []);
        FlutterError.onError = originalErrors;
        stage('after-production-main-call');
        await _until(
          tester,
          () => find.byType(XboardAppShell).evaluate().isNotEmpty,
          'application startup',
        );
        final container = globalState.container;
        booted = true;
        await _until(
          tester,
          () => find.text('同意并开始').evaluate().isNotEmpty,
          'brand welcome',
        );
        await tester.tap(find.text('同意并开始'));
        await _until(
          tester,
          () =>
              container.read(appSettingProvider).acceptedDisclaimerVersion ==
              disclaimerVersion,
          'brand consent persisted',
        );
        await _until(
          tester,
          () =>
              container.read(initProvider) &&
              container.read(coreStatusProvider) == CoreStatus.connected,
          'real core initialized',
        );
        FlutterError.onError = originalErrors;
        expect(container.read(networkSettingProvider).systemProxy, isFalse);
        expect(
          container.read(networkSettingProvider).autoSetSystemDns,
          isFalse,
        );
        expect(container.read(patchClashConfigProvider).tun.enable, isFalse);
        expect(container.read(authStateProvider), AuthState.unauthenticated);
        expect(container.read(apiEndpointProvider), panel.origin);
        expect(find.text(config.appName), findsWidgets);
        // Exercise the production login sheet and its authentication completion.
        unawaited(showLoginSheet(globalState.navigatorKey.currentContext!));
        await _until(
          tester,
          () => find.byType(LoginSheet).evaluate().isNotEmpty,
          'login sheet',
        );
        await _until(
          tester,
          () =>
              ModalRoute.of(
                tester.element(find.byType(LoginSheet)),
              )?.animation?.isCompleted ==
              true,
          'login route ready',
        );
        await tester.enterText(find.byType(TextField).at(0), _email);
        await tester.enterText(find.byType(TextField).at(1), _password);
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(0))
              .controller!
              .text,
          _email,
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(1))
              .controller!
              .text,
          _password,
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.widgetWithText(FilledButton, '登录'));
        await _until(
          tester,
          () => (panel.hits['/api/v1/passport/auth/login'] ?? 0) > 0,
          'login HTTP request',
        );
        await _until(
          tester,
          () => container.read(authStateProvider) == AuthState.authenticated,
          'SDK login and token persistence',
        );
        await _until(
          tester,
          () =>
              container.read(currentProfileIdProvider) != null &&
              jsonEncode(container.read(groupsProvider)).contains(_node),
          'encrypted subscription and core groups',
        );
        expect(panel.authorizedReads, greaterThan(0));
        expect(panel.hits['/sub/encrypted/fixture-sub-token'], greaterThan(0));
        final account = await container.read(userProfileProvider.future);
        expect(account.email, _email);
        expect(account.usedBytes, 3072);
        final id = container.read(currentProfileIdProvider)!;
        final profile = container
            .read(profilesProvider)
            .singleWhere((p) => p.id == id);
        expect(profile.url, isEmpty);
        final profileFile = File(await appPath.getProfilePath('$id'));
        expect(await profileFile.readAsString(), contains(_node));
        // Authentication/subscription can finish before the login route's
        // exit animation. Wait for its barrier to leave before clicking tabs.
        await _until(
          tester,
          () => find.byType(LoginSheet, skipOffstage: false).evaluate().isEmpty,
          'login route removed',
        );
        // The actual node page must render the imported node.
        await tester.tap(find.text('节点').first);
        await _until(
          tester,
          () => find.text(_node).evaluate().isNotEmpty,
          'node page',
        );
        await tester.tap(find.text('首页').first);
        await _until(
          tester,
          () => find.byType(XbConnectOrb).evaluate().isNotEmpty,
          'home',
        );
        await tester.tap(find.byType(XbConnectOrb));
        await _until(tester, () => container.read(isStartProvider), 'connect');
        await _listenerState(tester, proxyPort, true);
        final proxy = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
        try {
          final request = await proxy.getUrl(
            Uri.parse('${panel.origin}/core-proof'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          expect(
            await utf8.decoder.bind(response).join(),
            'native-core-forwarded',
          );
        } finally {
          proxy.close(force: true);
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await tester.tap(find.byType(XbConnectOrb));
        await _until(
          tester,
          () => !container.read(isStartProvider),
          'disconnect',
        );
        await _listenerState(tester, proxyPort, false);
        await File('${directory.path}/result.json').writeAsString(
          jsonEncode({
            'brand': config.flavorId,
            'name': config.appName,
            'passed': true,
            'steps': [
              'startup-from-bundled-fallback',
              'brand-icon-asset',
              'brand-welcome-consent',
              'login-sheet',
              'encrypted-subscription',
              'sqlite-profile',
              'node-page',
              'core-proxy-request',
              'disconnect-listener-closed',
            ],
            'http_counts': panel.hits,
            'system_proxy': false,
            'tun': false,
          }),
        );
        debugPrint('NATIVE_CHAIN_PASS ${config.flavorId}');
      } finally {
        // Flutter checks this invariant before addTearDown callbacks run.
        ErrorWidget.builder = originalErrorBuilder;
        FlutterError.onError = originalErrors;
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
