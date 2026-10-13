import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A one-shot UI notice for an expired current session; ordinary logout is silent.
final authExpiryNoticeProvider = NotifierProvider<AuthExpiryNotice, int>(
  AuthExpiryNotice.new,
);

class AuthExpiryNotice extends Notifier<int> {
  @override
  int build() => 0;

  void notifyExpired() => state++;
}
