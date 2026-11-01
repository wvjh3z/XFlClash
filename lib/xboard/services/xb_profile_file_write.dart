import 'dart:io';
import 'dart:typed_data';

/// A same-directory staged write. Never delete the destination to make room.
/// Caller serializes writes and checks session ownership before publication.
class XbProfileFileWrite {
  XbProfileFileWrite._(
    this.target,
    this.directory,
    this.candidate,
    this.backup,
    this.ensureCurrent,
    this.windows,
    this.retryDelays,
    this.wait,
    this.rename,
    this.readTarget,
  );

  final File target;
  final Directory directory;
  final File candidate;
  final File backup;
  final void Function() ensureCurrent;
  final bool windows;
  final List<Duration> retryDelays;
  final Future<void> Function(Duration) wait;
  final Future<File> Function(File, String) rename;
  final Future<Uint8List?> Function()? readTarget;
  Uint8List? _oldBytes;
  Uint8List? _newBytes;
  bool _published = false;
  bool _committed = false;
  bool _retainRecovery = false;

  static Future<XbProfileFileWrite> create({
    required String targetPath,
    required Uint8List bytes,
    required void Function() ensureCurrent,
    bool? windows,
    List<Duration> retryDelays = const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
      Duration(milliseconds: 400),
    ],
    Future<void> Function(Duration)? wait,
    Future<File> Function(File, String)? rename,
    Future<Uint8List?> Function()? readTarget,
  }) async {
    ensureCurrent();
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    ensureCurrent();
    final directory = await target.parent.createTemp('.xb-profile-');
    final operation = XbProfileFileWrite._(
      target,
      directory,
      File('${directory.path}/candidate.yaml'),
      File('${directory.path}/previous.yaml'),
      ensureCurrent,
      windows ?? Platform.isWindows,
      List.unmodifiable(retryDelays),
      wait ?? Future<void>.delayed,
      rename ?? (file, path) => file.rename(path),
      readTarget,
    );
    try {
      await operation.candidate.writeAsBytes(bytes, flush: true);
      ensureCurrent();
      return operation;
    } catch (error, stack) {
      final cleanupError = await operation.cleanup();
      if (cleanupError != null) {
        throw XbProfilePreparationFailure(error, cleanupError);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<Uint8List?> _readTarget() async {
    if (readTarget != null) return readTarget!();
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Profile destination is not a regular file',
        target.path,
      );
    }
    if (windows && ((await target.stat()).mode & 0x80) == 0) {
      throw _ProfileReadOnly(target.path);
    }
    return target.readAsBytes();
  }

  static bool _same(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Invoke only after the real core has validated candidate.path.
  Future<void> publish() async {
    var retries = 0;
    // One budget for the initial snapshot and every recheck/rename failure.
    // Backup/candidate I/O is outside this recovery scope.
    Future<T> retry<T>(Future<T> Function() operation) async {
      while (true) {
        ensureCurrent();
        try {
          return await operation();
        } on FileSystemException catch (error) {
          final code = error.osError?.errorCode;
          if (!windows ||
              error is _ProfileReadOnly ||
              (code != 5 && code != 32 && code != 33) ||
              retries >= retryDelays.length) {
            rethrow;
          }
          ensureCurrent();
          await wait(retryDelays[retries++]);
        }
      }
    }

    _oldBytes = await retry(_readTarget);
    ensureCurrent();
    if (_oldBytes != null) await backup.writeAsBytes(_oldBytes!, flush: true);
    _newBytes = await candidate.readAsBytes();
    await retry(() async {
      if (!_same(await _readTarget(), _oldBytes)) {
        throw FileSystemException('Profile changed during write', target.path);
      }
      ensureCurrent();
      await rename(candidate, target.path);
      _published = true;
    });
  }

  void commit() => _committed = true;

  /// Roll back only this write, never overwrite a newer external modification.
  Future<void> rollback() async {
    if (!_published || _committed) return;
    _retainRecovery = true;
    if (!_same(await _readTarget(), _newBytes)) {
      throw FileSystemException(
        'Profile changed before recovery; backup retained',
        backup.path,
      );
    }
    if (_oldBytes == null) {
      await target.delete();
    } else {
      await rename(backup, target.path);
    }
    _published = false;
    _retainRecovery = false;
  }

  /// Session cleanup owns the target after logout; do not resurrect old data.
  void abandonForSessionEnd() => _committed = true;

  /// Cleanup never masks the primary failure. Return its error for reporting.
  Future<Object?> cleanup() async {
    if (_retainRecovery) return null;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return null;
    } catch (error) {
      return error;
    }
  }
}

class XbProfilePreparationFailure implements Exception {
  const XbProfilePreparationFailure(this.cause, this.cleanupError);
  final Object cause;
  final Object cleanupError;
  @override
  String toString() => 'Profile staging failed; temporary cleanup also failed';
}

// A known permanent destination policy failure, not an OS sharing failure.
class _ProfileReadOnly extends FileSystemException {
  _ProfileReadOnly(String path)
    : super(
        'Profile destination is read-only',
        path,
        const OSError('Access denied', 5),
      );
}
