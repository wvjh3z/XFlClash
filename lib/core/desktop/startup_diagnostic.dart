import 'dart:async';
import 'dart:io';

import 'helper_client.dart';
import 'launch_policy.dart';
import 'launcher.dart';
import 'model.dart';

enum CoreStartupStage {
  bindIpc,
  resolveLauncher,
  startProcess,
  handshake,
  verifyPeer,
}

enum CoreStartupReason {
  ipcBindTimeout,
  ipcBindFailed,
  launcherResolutionFailed,
  processCreationFailed,
  helperStartFailed,
  sessionMismatch,
  exitedBeforeHandshake,
  handshakeTimeout,
  ipcHandshakeFailed,
  peerPidMismatch,
  unexpected,
}

/// A bounded snapshot, not an exception, path, process identity or log.
final class CoreStartupDiagnostic {
  const CoreStartupDiagnostic({
    required this.stage,
    required this.reason,
    required this.elapsedMs,
    required this.leaseAcquired,
    this.owner,
    this.osError,
    this.exitCode,
    this.ipcReadyMs,
    this.leaseAcquiredMs,
    this.peerSeenMs,
  });

  final CoreStartupStage stage;
  final CoreStartupReason reason;
  final int elapsedMs;
  final bool leaseAcquired;
  final CoreProcessOwner? owner;
  final int? osError;
  final int? exitCode;
  final int? ipcReadyMs;
  final int? leaseAcquiredMs;
  final int? peerSeenMs;
}

typedef CoreStartupObserver = void Function(CoreStartupDiagnostic diagnostic);

/// Absent by default. The application monitoring owner binds/unbinds this
/// observer; it has no process control and never receives the original error.
CoreStartupObserver? desktopCoreStartupObserver;

final class CoreStartupAttempt {
  final _clock = Stopwatch()..start();
  var stage = CoreStartupStage.bindIpc;
  CoreProcessOwner? _owner;
  int? _ipcReadyMs;
  int? _leaseAcquiredMs;
  int? _peerSeenMs;
  int? _exitCode;
  bool _exitObservationEnded = false;

  void ipcReady() {
    _ipcReadyMs = _clock.elapsedMilliseconds;
    stage = CoreStartupStage.resolveLauncher;
  }

  void launching(CoreProcessLauncher launcher) {
    stage = CoreStartupStage.startProcess;
    if (launcher is DirectCoreLauncher) _owner = CoreProcessOwner.direct;
    if (launcher is HelperLauncher) _owner = CoreProcessOwner.helper;
  }

  void acquired(CoreProcessLease lease) {
    _owner = lease.owner;
    _leaseAcquiredMs = _clock.elapsedMilliseconds;
    if (lease is DirectCoreLease) {
      unawaited(
        lease.startupExitCode.then<void>((code) {
          if (!_exitObservationEnded) _exitCode = code;
        }, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  void peerSeen() => _peerSeenMs ??= _clock.elapsedMilliseconds;

  void endExitObservation() => _exitObservationEnded = true;

  CoreStartupDiagnostic failure(Object error) {
    endExitObservation();
    final reason = switch ((stage, error)) {
      (_, DesktopCoreFailure(code: 'session_mismatch')) =>
        CoreStartupReason.sessionMismatch,
      (_, DesktopCoreFailure(code: 'peer_pid_mismatch')) =>
        CoreStartupReason.peerPidMismatch,
      (CoreStartupStage.bindIpc, TimeoutException()) =>
        CoreStartupReason.ipcBindTimeout,
      (CoreStartupStage.bindIpc, _) => CoreStartupReason.ipcBindFailed,
      (CoreStartupStage.resolveLauncher, _) =>
        CoreStartupReason.launcherResolutionFailed,
      (CoreStartupStage.startProcess, ProcessException()) =>
        CoreStartupReason.processCreationFailed,
      (CoreStartupStage.startProcess, HelperException()) =>
        CoreStartupReason.helperStartFailed,
      (CoreStartupStage.handshake, _)
          when _exitCode != null && _peerSeenMs == null =>
        CoreStartupReason.exitedBeforeHandshake,
      (CoreStartupStage.handshake, TimeoutException()) =>
        CoreStartupReason.handshakeTimeout,
      (CoreStartupStage.handshake, _) => CoreStartupReason.ipcHandshakeFailed,
      _ => CoreStartupReason.unexpected,
    };
    final owner = switch (reason) {
      CoreStartupReason.processCreationFailed => CoreProcessOwner.direct,
      CoreStartupReason.helperStartFailed => CoreProcessOwner.helper,
      _ => _owner,
    };
    return CoreStartupDiagnostic(
      stage: stage,
      reason: reason,
      elapsedMs: _clock.elapsedMilliseconds,
      leaseAcquired: _leaseAcquiredMs != null,
      owner: owner,
      osError: launchOsError(error),
      exitCode: _exitCode,
      ipcReadyMs: _ipcReadyMs,
      leaseAcquiredMs: _leaseAcquiredMs,
      peerSeenMs: _peerSeenMs,
    );
  }
}
