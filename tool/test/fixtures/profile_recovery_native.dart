import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'xb_profile_file_write.dart';
import 'profile_recovery_owner.dart';

Future<void> main(List<String> args) async {
  final root=Directory(args[1]);await root.create(recursive:true);
  final target=File('${root.path}/42.yaml');
  final owner=ProfileRecoveryOwner(args[2],args.length>3?args[3]:'owner');
  if(args[0]=='prepare') {
    await target.writeAsString('old-config');
    final op=await XbProfileFileWrite.create(targetPath:target.path,bytes:Uint8List.fromList('new-config'.codeUnits),ensureCurrent:(){},recoveryOwner:owner);
    print(jsonEncode({'directory':op.directory.path}));return;
  }
  var ok=true;int? code;
  try{await XbProfileFileWrite.cleanupOwned(targetPath:target.path,owner:owner);}on FileSystemException catch(e){ok=false;code=e.osError?.errorCode;}
  final dirs=await root.list().where((e)=>e is Directory).toList();
  print(jsonEncode({'ok':ok,'code':code,'directories':dirs.length,'markers':await Future.wait(dirs.map((e)=>File('${e.path}/owner.json').exists())),'old_preserved':await target.readAsString()=='old-config'}));
}
