import 'dart:io';import 'dart:convert';import 'dart:typed_data';
import 'xb_profile_file_write.dart';import 'profile_recovery_owner.dart';
Future<void> main(List<String> a)async{
 final root=Directory(a[0]);await root.create(recursive:true);
 final target=File('${root.path}/42.yaml');await target.writeAsString('old');
 final owner=ProfileRecoveryOwner(a[1],'owner');
 final op=await XbProfileFileWrite.create(targetPath:target.path,bytes:Uint8List.fromList('new'.codeUnits),ensureCurrent:(){},recoveryOwner:owner);
 await op.publish();op.commit();
 await File('${root.path}/ready.json').writeAsString(jsonEncode({'directory':op.directory.path}));
 Future<void> gate(String name)async {
  final clock=Stopwatch()..start();while(!await File('${root.path}/$name').exists()){if(clock.elapsed.inSeconds>20)throw StateError('gate timeout');await Future<void>.delayed(const Duration(milliseconds:20));}
 }
 await gate('go');
 final error=await op.cleanup();
 final retained=await File('${op.directory.path}/owner.json').exists();
 final backupRetained=await op.backup.exists();
 await File('${root.path}/failed.json').writeAsString(jsonEncode({'cleanup_failed':error!=null,'marker':retained,'backup':backupRetained}));
 await gate('released');
 await XbProfileFileWrite.cleanupOwned(targetPath:target.path,owner:owner);
 print(jsonEncode({'brand':a[1],'cleanup_failed':error!=null,'code':error is FileSystemException?error.osError?.errorCode:null,'owner_marker_retained':retained,'backup_retained':backupRetained,'recovery_directory_removed':!await op.directory.exists(),'target_new':await target.readAsString()=='new'}));
}
