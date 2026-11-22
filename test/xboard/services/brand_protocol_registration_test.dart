import 'package:fl_clash/common/protocol.dart';
import 'package:fl_clash/common/link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const brandScheme = String.fromEnvironment('XB_URL_SCHEME');
  if (brandScheme.isNotEmpty) {
    test('brand startup registration performs no system registration', () async {
      // Run on Linux too: reaching the original win32 registry path would fail.
      expect(() => protocol.register(brandScheme), returnsNormally);
      expect(() => protocol.register(brandScheme), returnsNormally);
      expect(protocolSchemes, isEmpty);
      await protocol.registerLinux([brandScheme]);
    });
    test('brand links do not subscribe or import queued external URLs', () async {
      final previous = linkManager.uriLinkStream;
      addTearDown(() { linkManager.destroy(); linkManager.uriLinkStream = previous; });
      linkManager.uriLinkStream = () => throw StateError('must not subscribe');
      linkManager.seedInitialLink(['$brandScheme://install-config?url=https://example.com/a.yaml']);
      await linkManager.initAppLinksListen((_) => fail('must not import'));
      expect(linkManager.subscription, isNull);
    });
  } else {
    test('unbranded schemes retain upstream defaults', () {
      expect(protocolSchemes, ['clash', 'clashmeta', 'flclash']);
    });
  }
}
