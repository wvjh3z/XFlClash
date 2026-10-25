import 'dart:async';
import 'dart:io';

/// Process-wide ownership for download/install operations. A stale release
/// cannot unlock a newer operation, and install completion can release later.
class XbUpdateGate {
  XbUpdateLease? _active;

  XbUpdateLease? acquire() {
    if (_active != null) return null;
    final lease = XbUpdateLease._(this);
    _active = lease;
    return lease;
  }
}

class XbUpdateLease {
  XbUpdateLease._(this._gate);
  final XbUpdateGate _gate;

  void release() {
    if (identical(_gate._active, this)) _gate._active = null;
  }
}

Future<void> xbWaitForInstaller(Process process, XbUpdateLease lease) async {
  unawaited(process.stdout.drain<void>().catchError((Object _) {}));
  unawaited(process.stderr.drain<void>().catchError((Object _) {}));
  try {
    await process.exitCode;
  } finally {
    lease.release();
  }
}
