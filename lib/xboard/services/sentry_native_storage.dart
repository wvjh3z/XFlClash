import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

import '../storage/brand_paths.dart';

/// Native Sentry otherwise writes relative to the process working directory,
/// which is normally the read-only installation directory on Windows.
Future<String?> prepareXbSentryNativeDatabase({
  bool? isWindows,
  Future<Directory> Function()? cacheDirectory,
}) async {
  if (!(isWindows ?? (!kIsWeb && Platform.isWindows))) return null;
  final cache = await (cacheDirectory ?? brandCacheDirectory)();
  final database = Directory(p.join(cache.path, 'sentry-native'));
  await database.create(recursive: true);
  return database.path;
}
