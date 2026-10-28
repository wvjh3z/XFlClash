import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';

void main() {
  tearDown(XboardConfig.resetForTest);
  for (final brand in ['brand_a', 'brand_b']) {
    for (final ipv6 in [true, false]) {
      test('$brand legacy IPv6 $ipv6 and test URL survive brand loading', () {
        XboardConfig.bind(
          XboardConfig(
            subscribeUserAgent: 'test',
            devApiEndpoint: 'https://api.example.invalid',
            devSubscriptionEndpoint: 'https://sub.example.invalid',
            debug: false,
            flavorId: brand,
            formA: true,
            kIsTest: true,
          ),
        );
        final saved = Config.strictFromJson({
          'appSettingProps': {'testUrl': 'https://example.invalid/custom'},
          'patchClashConfig': {'ipv6': ipv6, 'mode': 'direct'},
        });
        final c = ProviderContainer(overrides: buildConfigOverrides(saved));
        addTearDown(c.dispose);
        final config = c.read(patchClashConfigProvider);
        expect(config.mode, Mode.rule);
        expect(config.ipv6, ipv6);
        expect(
          config.toUpdateParams(authentication: [], skipCertVerify: false).ipv6,
          ipv6,
        );
        expect(
          c.read(realTestUrlProvider(null)),
          'https://example.invalid/custom',
        );
        expect(
          c.read(realTestUrlProvider('https://example.invalid/group')),
          'https://example.invalid/group',
        );
      });
    }
    test('$brand explicit new override choice survives loading', () {
      XboardConfig.bind(
        XboardConfig(
          subscribeUserAgent: 'test',
          devApiEndpoint: 'https://api.example.invalid',
          devSubscriptionEndpoint: 'https://sub.example.invalid',
          debug: false,
          flavorId: brand,
          formA: true,
          kIsTest: true,
        ),
      );
      final saved = Config.strictFromJson({
        'appSettingProps': {'testUrl': 'https://example.invalid/old'},
        'patchClashConfig': {
          'ipv6': true,
          'general-override-keys': <String>[],
          'test-url': 'https://example.invalid/new',
        },
      });
      final c = ProviderContainer(overrides: buildConfigOverrides(saved));
      addTearDown(c.dispose);
      final config = c.read(patchClashConfigProvider);
      expect(config.generalOverrideKeys, isEmpty);
      expect(
        config.toUpdateParams(authentication: [], skipCertVerify: false).ipv6,
        isNull,
      );
      expect(config.testUrl, 'https://example.invalid/new');
    });
  }
}
