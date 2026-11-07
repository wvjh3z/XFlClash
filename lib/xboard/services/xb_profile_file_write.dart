import 'dart:io';
import 'dart:convert';
import 'profile_recovery_owner.dart';
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
    this.remove,
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
  final Future<void> Function(FileSystemEntity) remove;
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
    ProfileRecoveryOwner? recoveryOwner,
    Future<void> Function(FileSystemEntity)? remove,
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
      remove ?? _deleteIfPresent,
    );
    try {
      if (recoveryOwner != null) {
        final marker = File('${directory.path}/owner.pending');
        await marker.writeAsString(
          jsonEncode({
            'schema': 1,
            'flavor': recoveryOwner.flavor,
            'owner': recoveryOwner.ownerHash,
            'profile': target.uri.pathSegments.last,
          }),
          flush: true,
        );
        await marker.rename('${directory.path}/owner.json');
      }
      ensureCurrent();
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

  /// Caller holds the existing flavor/owner mutation lane. Never recurse into
  /// unclassified directories or delete another owner's recovery material.
  static Future<void> cleanupOwned({
    required String targetPath,
    required ProfileRecoveryOwner owner,
    String? excludeDirectory,
    void Function()? ensureCurrent,
    ProfileRecoveryDiagnostics? diagnostics,
    Future<List<int>> Function(File)? readMetadata,
  }) async {
    final target = File(targetPath);
    ensureCurrent?.call();
    final List<FileSystemEntity> entries;
    try {
      entries = await target.parent.list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      if (await _confirmedMissing(target.parent.path, error)) return;
      rethrow;
    }
    for (final entity in entries) {
      ensureCurrent?.call();
      final name = entity.path.replaceAll('\\', '/').split('/').last;
      if (!name.startsWith('.xb-profile-') || entity.path == excludeDirectory) {
        continue;
      }
      if (await _typeWithErrors(entity.path) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final marker = File('${entity.path}/owner.json');
      if (await _typeWithErrors(marker.path) != FileSystemEntityType.file) {
        continue;
      }
      final Object? decoded;
      try {
        // Decode explicitly: invalid UTF-8 is a format warning, while genuine
        // read/permission/disk errors retain their FileSystemException semantics.
        final bytes =
            await (readMetadata?.call(marker) ?? marker.readAsBytes());
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        ensureCurrent?.call();
        diagnostics?.report(ProfileRecoveryWarning.malformedMetadata);
        continue;
      } on FileSystemException catch (error) {
        if (await _confirmedMissing(marker.path, error)) continue;
        rethrow;
      }
      ensureCurrent?.call();
      if (decoded is! Map || decoded['schema'] != 1) {
        diagnostics?.report(ProfileRecoveryWarning.unsupportedSchema);
        continue;
      }
      final identity = [
        decoded['flavor'],
        decoded['owner'],
        decoded['profile'],
      ];
      if (identity.any((value) => value is! String || value.isEmpty)) {
        diagnostics?.report(ProfileRecoveryWarning.invalidIdentity);
        continue;
      }
      if (decoded['flavor'] != owner.flavor ||
          decoded['owner'] != owner.ownerHash ||
          decoded['profile'] != target.uri.pathSegments.last) {
        continue;
      }
      await _cleanupDirectory(
        Directory(entity.path),
        ensureCurrent: ensureCurrent,
      );
    }
  }

  /// Shared by in-flight cleanup and historical recovery. Never recursively
  /// remove a marker before knowing that all plaintext has been removed.
  static Future<void> _cleanupDirectory(
    Directory directory, {
    void Function()? ensureCurrent,
    Future<void> Function(FileSystemEntity)? remove,
  }) async {
    final delete = remove ?? _deleteIfPresent;
    const payloads = ['candidate.yaml', 'previous.yaml'];
    const markers = ['owner.pending', 'owner.json'];
    ensureCurrent?.call();
    final type = await _typeWithErrors(directory.path);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Recovery directory changed; retained',
        directory.path,
      );
    }
    Future<List<FileSystemEntity>?> children() async {
      try {
        return await directory.list(followLinks: false).toList();
      } on FileSystemException catch (error) {
        if (await _confirmedMissing(directory.path, error)) return null;
        rethrow;
      }
    }

    Future<void> validate(
      List<FileSystemEntity> entries, {
      required bool plaintextAllowed,
    }) async {
      for (final entry in entries) {
        ensureCurrent?.call();
        final entryType = await _typeWithErrors(entry.path);
        if (entryType == FileSystemEntityType.notFound) continue;
        final name = entry.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        if ((!markers.contains(name) &&
                !(plaintextAllowed && payloads.contains(name))) ||
            entryType != FileSystemEntityType.file) {
          throw FileSystemException(
            'Unexpected recovery entry; marker retained',
            entry.path,
          );
        }
      }
    }

    final initial = await children();
    if (initial == null) return;
    await validate(initial, plaintextAllowed: true);
    Future<void> removeFile(String name) async {
      ensureCurrent?.call();
      final file = File('${directory.path}/$name');
      final fileType = await _typeWithErrors(file.path);
      if (fileType == FileSystemEntityType.notFound) return;
      if (fileType != FileSystemEntityType.file) {
        throw FileSystemException(
          'Recovery entry changed; retained',
          file.path,
        );
      }
      await delete(file);
    }

    for (final name in payloads) {
      await removeFile(name);
    }
    // Detect a reappeared payload or unexpected entry before losing ownership.
    final remaining = await children();
    if (remaining == null) return;
    await validate(remaining, plaintextAllowed: false);
    for (final name in markers) {
      await removeFile(name);
    }
    ensureCurrent?.call();
    await delete(directory); // non-recursive: any new entry causes a failure
  }

  /// type()/stat()/exists() can hide lookup errors. When type is unknown,
  /// enumerate the parent without following links; this preserves I/O failures
  /// and distinguishes an absent entry from an inaccessible one.
  static Future<FileSystemEntityType> _typeWithErrors(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) return type;
    String basename(Uri uri) =>
        uri.pathSegments.where((part) => part.isNotEmpty).last;
    final target = File(path);
    if (target.uri.pathSegments.every((part) => part.isEmpty)) {
      throw FileSystemException('Cannot determine filesystem root type', path);
    }
    final wanted = basename(target.uri);
    try {
      await for (final entry in target.parent.list(followLinks: false)) {
        final name = basename(entry.uri);
        if (Platform.isWindows
            ? name.toLowerCase() != wanted.toLowerCase()
            : name != wanted) {
          continue;
        }
        if (entry is Link) return FileSystemEntityType.link;
        if (entry is Directory) return FileSystemEntityType.directory;
        if (entry is File) return FileSystemEntityType.file;
        throw FileSystemException('Cannot determine profile entry type', path);
      }
      return FileSystemEntityType.notFound;
    } on FileSystemException catch (error) {
      if (_isMissing(error) &&
          target.parent.absolute.path != target.absolute.path &&
          await _typeWithErrors(target.parent.path) ==
              FileSystemEntityType.notFound) {
        return FileSystemEntityType.notFound;
      }
      rethrow;
    }
  }

  static Future<void> removeFileIfPresent(String path) =>
      _deleteIfPresent(File(path));

  // Some native Dart operations replace a lookup error with ENOENT. Confirm
  // absence independently before accepting even a "not found" error code.
  static Future<bool> _confirmedMissing(
    String path,
    FileSystemException error,
  ) async =>
      _isMissing(error) &&
      await _typeWithErrors(path) == FileSystemEntityType.notFound;

  static bool _isMissing(FileSystemException error) {
    final code = error.osError?.errorCode;
    return code == 2 || (Platform.isWindows && code == 3);
  }

  static Future<void> _deleteIfPresent(FileSystemEntity entity) async {
    try {
      await entity.delete();
    } on FileSystemException catch (error) {
      if (!await _confirmedMissing(entity.path, error)) rethrow;
    }
  }

  Future<Uint8List?> _readTarget() async {
    if (readTarget != null) return readTarget!();
    final type = await _typeWithErrors(target.path);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Profile destination is not a regular file',
        target.path,
      );
    }
    if (windows) {
      final stat = await target.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Profile attributes unavailable',
          target.path,
        );
      }
      if ((stat.mode & 0x80) == 0) throw _ProfileReadOnly(target.path);
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
      await _cleanupDirectory(directory, remove: remove);
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
