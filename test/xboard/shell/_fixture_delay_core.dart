import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart' show Delay, TestDelayParams;
import 'package:fl_clash/providers/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

// Exercise the real connection/selection/sample path without crossing native IPC.
class FixtureDelayCore extends Fake implements CoreHandlerInterface {
  int calls = 0;
  int sample = 48;

  @override
  Future<Delay> testDelay(TestDelayParams params) async {
    calls++;
    return Delay(name: params.proxyName, url: params.testUrl, value: sample);
  }
}

Override fixtureDelayCoreOverride() =>
    coreHandlerProvider.overrideWithValue(CoreController.scoped(FixtureDelayCore()));
