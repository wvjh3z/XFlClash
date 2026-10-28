import 'dart:io';

import 'xb_appimage_restart.dart';

/// Keep the old image until preparation and the exit request have succeeded.
/// All rollback artifacts stay beside the target (same filesystem).
Future<void> xbInstallAppImage({
  required String downloadedPath,
  required String appImagePath,
  required Future<void> Function() requestExit,
  Future<XbAppImageRestartTicket> Function(String)? prepareRestart,
}) async {
  final target = File(appImagePath);
  if (!await target.exists()) throw StateError('AppImage is missing');
  final staging = await target.parent.createTemp('.xb_appimage_update-');
  final backup = File('${staging.path}/previous.AppImage');
  XbAppImageRestartTicket? ticket;
  var replaced = false;
  var restoreFailed = false;
  var committed = false;
  try {
    final replacement = await File(
      downloadedPath,
    ).copy('${staging.path}/replacement');
    final chmod = await Process.run('chmod', ['+x', replacement.path]);
    if (chmod.exitCode != 0) {
      throw StateError('Cannot make AppImage executable');
    }
    await target.copy(backup.path);
    ticket = await (prepareRestart != null
        ? prepareRestart(appImagePath)
        : xbPrepareAppImageRestart(appImagePath, backupPath: backup.path));
    await replacement.rename(appImagePath);
    replaced = true;
    await ticket.commit();
    await requestExit();
    committed = true;
  } catch (_) {
    // The old app is still alive when an exit request fails. Cancel its waiter
    // before restoring the original path; never leave a late restart armed.
    Object? cancelFailure;
    try {
      await ticket?.cancel();
    } catch (error) {
      cancelFailure = error;
    }
    if (replaced) {
      try {
        await backup.rename(appImagePath);
      } catch (_) {
        restoreFailed = true;
        throw StateError('AppImage recovery retained at ${backup.path}');
      }
    }
    if (cancelFailure != null) {
      throw StateError(
        'AppImage restored but restart cancellation failed: $cancelFailure',
      );
    }
    rethrow;
  } finally {
    // Real handleExit normally terminates the process rather than returning.
    // Preserve the backup then; a failed restore must never delete it.
    if (!restoreFailed && (!replaced || !committed)) {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
