/// Brand product modes. The upstream enum and non-branded client stay intact.
library;

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show PatchClashConfig;
import 'xboard_config.dart';

List<Mode> get xbAvailableModes =>
    XboardConfig.current.formA ? const [Mode.rule, Mode.global] : Mode.values;

PatchClashConfig xbNormalizeModeConfig(PatchClashConfig config) =>
    XboardConfig.current.formA && config.mode == Mode.direct
    ? config.copyWith(mode: Mode.rule)
    : config;
