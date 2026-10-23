/// Desktop data roots must not use path_provider_linux's legacy executable-name fallback.
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const nativeBrandId = String.fromEnvironment('XB_NATIVE_ID');
const brandSlug = String.fromEnvironment('XB_BRAND_SLUG');
bool get isolatedDesktopBrand =>
    nativeBrandId.isNotEmpty &&
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Future<Directory> brandSupportDirectory(
  Future<Directory> Function() native,
) async {
  if (!isolatedDesktopBrand || !Platform.isLinux) return native();
  return linuxBrandDirectory(cache: false);
}

Future<Directory> brandCacheDirectory() => brandCacheRoot(getApplicationCacheDirectory);

Future<Directory> brandCacheRoot(Future<Directory> Function() native) async {
  if (!isolatedDesktopBrand || !Platform.isLinux) return native();
  return linuxBrandDirectory(cache: true);
}

Future<Directory> linuxBrandDirectory({
  required bool cache,
  Map<String, String>? environment,
  String id = nativeBrandId,
}) async {
  final env = environment ?? Platform.environment;
  if (!RegExp(r'^com\.cloud\.app\.(omofly|daishu)$').hasMatch(id)) {
    throw StateError('Invalid desktop brand data identity');
  }
  final home = env['HOME'];
  if (home == null || !p.isAbsolute(home)) {
    throw StateError('Missing user home');
  }
  final custom = env[cache ? 'XDG_CACHE_HOME' : 'XDG_DATA_HOME'];
  final root = custom != null && p.isAbsolute(custom)
      ? custom
      : p.join(home, cache ? '.cache' : '.local/share');
  final result = Directory(p.join(root, id));
  await result.create(recursive: true);
  return result;
}

Future<Directory> brandTemporaryDirectory() => brandTemporaryRoot(getTemporaryDirectory);

Future<Directory> brandTemporaryRoot(Future<Directory> Function() native) async {
  if (!isolatedDesktopBrand) return native();
  // Use a per-user cache root, never a predictable shared /tmp/<brand> folder.
  final cache = await brandCacheDirectory();
  return Directory(p.join(cache.path, 'temporary')).create(recursive: true);
}
