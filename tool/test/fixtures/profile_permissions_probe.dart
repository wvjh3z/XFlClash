import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'xb_profile_file_write.dart';
import 'profile_recovery_owner.dart';

Future<void> main(List<String> args) async {
  final root=args[0], brand=args[1], action=args[2];
  var ok=true; int? code;
  try {
    if(action=='delete') {
      await XbProfileFileWrite.removeFileIfPresent('$root/42.yaml');
    } else if(action=='stage_cleanup') {
      final op=await XbProfileFileWrite.create(targetPath:'$root/42.yaml',bytes:Uint8List.fromList([1]),ensureCurrent:(){},recoveryOwner:ProfileRecoveryOwner(brand,'owner'));
      final chmod=await Process.run('chmod',['600',root]);
      if(chmod.exitCode!=0)throw StateError('fixture chmod failed');
      try {
        final error=await op.cleanup();
        if(error!=null) {
          ok=false;
          if(error is FileSystemException)code=error.osError?.errorCode;
        }
      } finally {
        final restored=await Process.run('chmod',['700',root]);
        if(restored.exitCode!=0)throw StateError('fixture chmod restore failed');
      }
    } else {
      await XbProfileFileWrite.cleanupOwned(targetPath:'$root/42.yaml',owner:ProfileRecoveryOwner(brand,'owner'));
    }
  } on FileSystemException catch(error) {ok=false;code=error.osError?.errorCode;}
  print(jsonEncode({'brand':brand,'action':action,'ok':ok,'code':code}));
}
