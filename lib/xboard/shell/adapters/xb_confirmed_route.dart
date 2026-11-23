import 'package:fl_clash/enum/enum.dart' show GroupType, Mode;
import 'package:fl_clash/models/models.dart' show Group;
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Follow the home route's entry group, but only trust the Core's `now`
/// readback. The optimistic selectedMap (and the first member fallback) are
/// useful for UI, not evidence that the egress changed successfully.
String? xbConfirmedRouteLeaf(List<Group> groups, Mode mode) {
  if (mode == Mode.direct) return null;
  final byName = {for (final group in groups) group.name: group};
  var group = mode == Mode.global
      ? byName['GLOBAL']
      : groups.where((g) => g.name != 'GLOBAL' && g.hidden != true).firstOrNull;
  final seen = <String>{};
  while (group != null && seen.add(group.name)) {
    if (group.type == GroupType.LoadBalance || group.type == GroupType.Relay) {
      return null;
    }
    final next = group.now;
    if (next == null || next.isEmpty || !group.all.any((p) => p.name == next)) {
      return null;
    }
    if (!byName.containsKey(next)) return next;
    group = byName[next];
  }
  return null;
}

typedef XbConfirmedRoute = ({int? profile, Mode mode, String leaf});

final xbConfirmedRouteProvider = Provider<XbConfirmedRoute?>((ref) {
  if (!ref.watch(isStartProvider) || ref.watch(suspendProvider)) return null;
  final mode = ref.watch(patchClashConfigProvider.select((p) => p.mode));
  final leaf = xbConfirmedRouteLeaf(ref.watch(groupsProvider), mode);
  if (leaf == null) return null;
  return (profile: ref.watch(currentProfileIdProvider), mode: mode, leaf: leaf);
});

ProviderSubscription<XbConfirmedRoute?> listenConfirmedNodeChanges(
  ProviderContainer container, {
  required void Function() onChange,
  required void Function() onReset,
}) => container.listen(xbConfirmedRouteProvider, (previous, next) {
  if (previous == null ||
      next == null ||
      previous.profile != next.profile ||
      previous.mode != next.mode) {
    onReset();
  } else if (previous.leaf != next.leaf) {
    onChange();
  }
}, fireImmediately: true);
