import 'dart:async';
import 'dart:convert';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/providers/catalog_read_cache.dart';
import 'package:fl_clash/xboard/providers/display_snapshot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('cold start reads fresh disk data; stale data precedes refresh and is scoped', (t) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final response = Completer<List<PlanItem>>();
    List<PlanItem> plans(int id) => [PlanItem(id: id, name: '套餐$id', transferEnableGb: 12, prices: [])];
    final fetched = FutureProvider<List<PlanItem>>((ref) => readDisplaySnapshot(
      ref, ref.watch(shopReadCacheProvider), 'shop', 'plans', planSnapshots, () async {
        calls++;
        return calls == 2 ? response.future : plans(calls);
      },
    ));
    ProviderContainer open(String owner) => ProviderContainer(overrides: [
      displaySnapshotKeyProvider.overrideWithValue(owner),
      shopReadCacheProvider.overrideWithValue(CatalogReadCache(() => Duration.zero)),
    ]);
    var c = open('first');
    expect((await c.read(fetched.future)).single.id, 1);
    c.dispose();
    c = open('first');
    expect((await c.read(fetched.future)).single.id, 1);
    expect(calls, 1);
    c.dispose();
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getKeys().single;
    final stored = jsonDecode(prefs.getString(key)!) as List;
    stored[0] = DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch;
    await prefs.setString(key, jsonEncode(stored));
    c = open('first');
    c.listen(fetched, (_, _) {});
    expect((await c.read(fetched.future)).single.id, 1);
    await t.pump();
    final refresh = c.read(fetched.future);
    response.complete(plans(2));
    expect((await refresh).single.id, 2);
    c.dispose();
    c = open('second');
    expect((await c.read(fetched.future)).single.id, 3);
    c.dispose();
  });
}
