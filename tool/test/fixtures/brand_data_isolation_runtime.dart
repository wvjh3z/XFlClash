// Local filesystem/SQLite regression, not an installed-device test.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/preferences_store.dart';
import 'package:fl_clash/xboard/data/xboard_database.dart';
import 'package:fl_clash/xboard/storage/brand_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override Future<String?> getApplicationSupportPath() async => '$root/legacy';
  @override Future<String?> getApplicationDocumentsPath() async => '$root/documents';
  @override Future<String?> getApplicationCachePath() async => '$root/legacy-cache';
  @override Future<String?> getTemporaryPath() async => '$root/temp';
  @override Future<String?> getDownloadsPath() async => '$root/downloads';
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compiled brand stores real SQLite/preferences outside shared legacy data', () async {
    final root=Platform.environment['XFLCLASH_IDENTITY_TEST_ROOT'];
    if(root==null || nativeBrandId.isEmpty || !Platform.isLinux) {
      throw StateError('Requires isolated Linux fixture root and compiled brand defines');
    }
    PathProviderPlatform.instance=_Paths(root);
    final old=File('$root/legacy/database.sqlite');
    await old.parent.create(recursive:true);await old.writeAsString('legacy sentinel');
    final before=await old.readAsBytes();
    final home=await appPath.homeDirPath;
    expect(home,'$root/data/$nativeBrandId');
    expect(await appPath.tempPath,'$root/cache/$nativeBrandId/temporary');
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance=AtomicFilePreferencesStore(appPath.sharedPreferencesPath);
    final preferences=await SharedPreferences.getInstance();
    await preferences.setString('brand-fixture',nativeBrandId);
    final db=XboardDatabase();
    await db.putIndex(profileId:1,flavorId:const String.fromEnvironment('XB_FLAVOR_ID'),userIdHash:'public-fixture');
    expect((await db.allRows()).single.flavorId,const String.fromEnvironment('XB_FLAVOR_ID'));
    await db.close();
    expect(await File('$home/xboard_index.sqlite').exists(),isTrue);
    expect(await File('$root/documents/xboard_index.sqlite').exists(),isFalse);
    expect(await old.readAsBytes(),before);
    expect(await File(await appPath.sharedPreferencesPath).readAsString(),contains(nativeBrandId));
  });
}
