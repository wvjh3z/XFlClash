import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'xb_profile_file_write.dart';
import 'profile_recovery_owner.dart';

Future<void> main(List<String> args) async {
  final target=File(args[1]);
  var attempts=0, waits=0; bool current=true, cancelled=false;
  XbProfileFileWrite? write;
  int? code; bool ok=false;
  try {
    write=await XbProfileFileWrite.create(targetPath:target.path,recoveryOwner:ProfileRecoveryOwner(target.path.contains('brand_b')?'brand_b':'brand_a','fixture-owner'),
      bytes:Uint8List.fromList('new-config'.codeUnits),ensureCurrent:(){if(!current)throw StateError('fixture session ended');},
      rename:(f,p)async{attempts++;return f.rename(p);},
      wait: (delay)async{
        waits++;
        if(args.length<=2){await Future<void>.delayed(delay);return;}
        final ready=File('${args[2]}/ready');final release=File('${args[2]}/release');
        await ready.writeAsString('ready');
        final deadline=Stopwatch()..start();
        while(!await release.exists()){
          if(deadline.elapsed>const Duration(seconds:10))throw StateError('release not signalled');
          await Future<void>.delayed(const Duration(milliseconds:10));
        }
        if(args.length>3&&args[3]=='cancel')current=false;
      });
    await write.publish();write.commit();ok=true;
  } on FileSystemException catch(e){code=e.osError?.errorCode;} on StateError {if(!current){cancelled=true;}else{rethrow;}}
  final cleanupError=await write?.cleanup();
  final type=await FileSystemEntity.type(target.path,followLinks:false);
  String? value;
  try{if(type==FileSystemEntityType.file)value=await target.readAsString();}on FileSystemException{}
  print(jsonEncode({'ok':ok,'code':code,'attempts':attempts,'waits':waits,'cancelled':cancelled,
    'old_preserved':value=='old-config','new_present':value=='new-config',
    'target_type':'$type','cleanup_ok':cleanupError==null,
    'staging_removed':write==null || !await write.directory.exists()}));
}
