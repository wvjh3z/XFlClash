import 'dart:io';
import '../brand_identity.dart';
void main(List<String> args) {
  final file=File(args[0]);
  file.writeAsStringSync(injectStableIdentity(file.readAsStringSync(),args[1],
      brandIdentity(args[2]),platform:args[3]));
}
