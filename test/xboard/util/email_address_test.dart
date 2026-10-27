import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/util/email_address.dart';
void main() {
 test('complete email never gets another suffix and preserves recipient', () {
   expect(xbComposeEmail(' User+tag@EXAMPLE.test ', ['example.test'], 'other.test'), 'User+tag@EXAMPLE.test');
   expect(xbComposeEmail('user@other.test', ['example.test'], 'example.test'), isNull);
   expect(xbComposeEmail('user@other.test', [], null),'user@other.test');
 });
 test('prefix selection and changing whitelist use the same normalized choices', () {
   expect(xbEmailSuffixes([' @EXAMPLE.test ','example.test','other.test']),['example.test','other.test']);
   expect(xbComposeEmail('user', ['example.test','other.test'], 'OTHER.test'),'user@other.test');
   expect(xbComposeEmail('user', ['example.test'], 'removed.test'),'user@example.test');
 });
 test('invalid addresses never reach submit', () {
   for(final input in ['', 'user@', '@example.test', 'a@@example.test', 'a b@example.test', 'a\u0000b@example.test','a\nb@example.test']) {
     expect(xbComposeEmail(input,['example.test'],null),isNull,reason:input);
   }
   expect(xbComposeEmail('prefix',[],null),isNull);
 });
}
