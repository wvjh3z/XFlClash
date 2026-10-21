import 'dart:io';

/// Process-lifetime, non-blocking OS lock. The file must never be unlinked:
/// replacing its inode would allow a second process to lock a different file.
class SingleInstanceLock {
  SingleInstanceLock({required Future<String> Function() lockFilePath})
    : _lockFilePath = lockFilePath;

  final Future<String> Function() _lockFilePath;
  RandomAccessFile? _accessFile;
  Future<bool>? _pending;

  Future<bool> acquire() {
    if (_accessFile != null) return Future.value(true);
    return _pending ??= _acquire().whenComplete(() => _pending = null);
  }

  Future<bool> _acquire() async {
    // Opening/path failures are real startup failures, not proof of a duplicate.
    final file = await File(await _lockFilePath()).open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      await file.close();
      final code = error.osError?.errorCode;
      // Windows ERROR_LOCK_VIOLATION; POSIX EAGAIN (or EACCES from fcntl).
      final busyCode = Platform.isWindows ? 33 : (Platform.isMacOS ? 35 : 11);
      final occupied = code == busyCode || (!Platform.isWindows && code == 13);
      if (occupied) return false;
      rethrow;
    } catch (_) {
      await file.close();
      rethrow;
    }
    _accessFile = file;
    return true;
  }

  /// Only call after all work using the protected data has stopped.
  /// Production keeps the handle until process exit; tests release explicitly.
  Future<void> release() async {
    await _pending;
    final file = _accessFile;
    if (file == null) return;
    await file.close();
    _accessFile = null;
  }
}
