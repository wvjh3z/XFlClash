// Standalone native Dart filesystem probe; no Flutter build or packages.
// Run: dart tool/test/fixtures/native_storage_paths.dart
// Verifies Dart I/O only, not path_provider identity or SQLite native assets.
import 'dart:io';
import 'dart:convert';
Future<void> main() async {
 final root=await Directory.systemTemp.createTemp('xb-storage-audit-');
 try {
  for(final slug in ['omofly','daishu']) {
   final dir=Directory('${root.path}/中文 用户/$slug/${'deep-'*25}/${'nested-'*20}');
   await dir.create(recursive:true);
   final lock=await File('${dir.path}/FlClash.lock').open(mode:FileMode.append);
   await lock.lock(FileLock.exclusive);
   try {
    final tmp=File('${dir.path}/测试.json.tmp');
    await tmp.writeAsString(jsonEncode({'brand':slug}),flush:true);
    final target=await tmp.rename('${dir.path}/测试.json');
    if(jsonDecode(await target.readAsString())['brand']!=slug) throw StateError('readback');
    stdout.writeln('$slug: unicode/long path/write/rename/read/lock passed; length=${target.path.length}');
   } finally { await lock.close(); }
  }
 } finally { await root.delete(recursive:true); }
}
