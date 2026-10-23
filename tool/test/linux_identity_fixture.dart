import 'dart:io';
import '../brand_identity.dart';
import '../inject_desktop_brand.dart';
void main(List<String> args) {
  final id=brandIdentity(args[1]);
  for (final kind in ['deb','rpm','appimage']) {
    final path='linux/packaging/$kind/make_config.yaml';
    final source=File('${args[0]}/$path').readAsStringSync();
    final output=File(path)..parent.createSync(recursive:true);
    output.writeAsStringSync(injectStableIdentity(
      injectMakeConfigNames(source,id['name'] as String),path,id,platform:'linux'));
  }
}
