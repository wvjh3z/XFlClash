import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

String _canonical(String value) {
  if (!Platform.isLinux) return p.posix.normalize(value);
  try {
    return File(value).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.posix.normalize(value);
  }
}

/// A launch marker must describe this executable, not its AppImage parent.
String? crispAppImageRoot({
  bool? isLinux,
  Map<String, String>? environment,
  String? executable,
}) {
  if (!(isLinux ?? Platform.isLinux)) {
    return null;
  }
  final env = environment ?? Platform.environment;
  final exe = _canonical(executable ?? Platform.resolvedExecutable);
  final markedRoot = env['XBOARD_APPIMAGE_ROOT'];
  final markedExe = env['XBOARD_APPIMAGE_EXECUTABLE'];
  if (markedRoot != null || markedExe != null) {
    if (markedRoot == null ||
        markedExe == null ||
        !p.posix.isAbsolute(markedRoot) ||
        !p.posix.isAbsolute(markedExe)) {
      return null;
    }
    final root = _canonical(markedRoot);
    return _canonical(markedExe) == exe && p.posix.dirname(exe) == root
        ? root
        : null;
  }
  // Compatibility with an older, mounted AppImage runtime. A bare APPIMAGE
  // filename cannot establish which process is actually running in that image.
  final root = env['APPDIR'];
  if (root == null ||
      !p.posix.isAbsolute(root) ||
      (env['APPIMAGE']?.trim().isEmpty ?? true)) {
    return null;
  }
  final canonical = _canonical(root);
  return p.posix.dirname(exe) == canonical ? canonical : null;
}

/// Restore host settings without changing this process's environment.
Map<String, String> crispBrowserEnvironment(
  Map<String, String> original, {
  required String appRoot,
  required String currentDirectory,
}) {
  final result = Map<String, String>.from(original);
  final root = _canonical(appRoot);
  bool owned(String value) {
    final resolved = _canonical(value);
    return resolved == root || p.posix.isWithin(root, resolved);
  }

  final savedCwd = original['XBOARD_APPIMAGE_ORIGINAL_CWD'];
  final saved =
      original['XBOARD_APPIMAGE_ENV_SAVED'] == '1' &&
      savedCwd != null &&
      p.posix.isAbsolute(savedCwd);
  // Loader tokens must be expanded by the child's loader, never by path.normalize.
  final loaderToken = RegExp(
    r'\$(?:\{(?:ORIGIN|LIB|PLATFORM)\}|(?:ORIGIN|LIB|PLATFORM)\b)',
  );
  String? cleanEntry(
    String entry,
    String base, {
    bool loader = false,
    bool soname = false,
  }) {
    if (loader) {
      final token = loaderToken.firstMatch(entry);
      if (token != null) {
        // Only a literal absolute directory prefix can establish ownership.
        final prefix = entry.substring(0, token.start);
        if (p.posix.isAbsolute(prefix) &&
            prefix.endsWith('/') &&
            owned(prefix)) {
          return null;
        }
        return entry;
      }
      if (soname && !entry.contains('/')) return entry;
    }
    final path = p.posix.normalize(
      p.posix.isAbsolute(entry) ? entry : p.posix.join(base, entry),
    );
    return owned(path) ? null : path;
  }

  String cleanPaths(String value, String base, {bool loader = false}) => value
      .split(loader ? RegExp(r'[:;]') : RegExp(':'))
      .map((entry) => cleanEntry(entry, base, loader: loader))
      .whereType<String>()
      .join(':');
  if (saved) {
    if (original['XBOARD_APPIMAGE_ORIGINAL_LD_SET'] == 'x') {
      final clean = cleanPaths(
        original['XBOARD_APPIMAGE_ORIGINAL_LD'] ?? '',
        savedCwd,
        loader: true,
      );
      if (clean.isEmpty) {
        result.remove('LD_LIBRARY_PATH');
      } else {
        result['LD_LIBRARY_PATH'] = clean;
      }
    } else {
      result.remove('LD_LIBRARY_PATH');
    }
  } else if (result['LD_LIBRARY_PATH'] case final String paths) {
    final clean = cleanPaths(paths, currentDirectory, loader: true);
    if (clean.isEmpty) {
      result.remove('LD_LIBRARY_PATH');
    } else {
      result['LD_LIBRARY_PATH'] = clean;
    }
  }
  for (final key in ['PATH', 'GTK_PATH', 'GI_TYPELIB_PATH', 'XDG_DATA_DIRS']) {
    if (result[key] case final String paths) {
      final clean = cleanPaths(paths, saved ? savedCwd : currentDirectory);
      if (clean.isEmpty) {
        result.remove(key);
      } else {
        result[key] = clean;
      }
    }
  }
  for (final key in [
    'GIO_MODULE_DIR',
    'GSETTINGS_SCHEMA_DIR',
    'GDK_PIXBUF_MODULE_FILE',
    'GTK_IM_MODULE_FILE',
    'GTK_EXE_PREFIX',
    'GTK_DATA_PREFIX',
  ]) {
    if (result[key] case final String value) {
      final path = cleanEntry(value, saved ? savedCwd : currentDirectory);
      if (path == null) {
        result.remove(key);
      } else {
        result[key] = path;
      }
    }
  }
  for (final key in ['LD_PRELOAD', 'LD_AUDIT']) {
    if (result[key] case final String value) {
      // LD_PRELOAD accepts spaces and colons; LD_AUDIT only colons.
      // Parse complete entries before testing containment, never substrings.
      final kept = value
          .split(key == 'LD_PRELOAD' ? RegExp(r'[ :]+') : RegExp(':'))
          .where((entry) => entry.isNotEmpty)
          .map(
            (entry) => cleanEntry(
              entry,
              saved ? savedCwd : currentDirectory,
              loader: true,
              soname: true,
            ),
          )
          .whereType<String>()
          .toList();
      if (kept.isEmpty) {
        result.remove(key);
      } else {
        result[key] = kept.join(':');
      }
    }
  }
  result.removeWhere(
    (key, _) =>
        key.startsWith('XBOARD_APPIMAGE_') ||
        const ['APPDIR', 'APPIMAGE', 'ARGV0', 'OWD'].contains(key),
  );
  result.putIfAbsent('PATH', () => '/usr/local/bin:/usr/bin:/bin');
  return result;
}

/// Launch only the host's opener; never a binary found in the AppDir PATH.
Future<bool> openCrispAppImageBrowser(
  Uri uri, {
  Map<String, String>? environment,
  String? executable,
  String? currentDirectory,
  List<List<String>> commands = const [
    ['/usr/bin/xdg-open'],
    ['/usr/bin/gio', 'open'],
  ],
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (uri.scheme != 'https' ||
      uri.host != 'go.crisp.chat' ||
      uri.path != '/chat/embed/' ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  final env = environment ?? Platform.environment;
  final root = crispAppImageRoot(environment: env, executable: executable);
  if (root == null) {
    return false;
  }
  final clean = crispBrowserEnvironment(
    env,
    appRoot: root,
    currentDirectory: currentDirectory ?? Directory.current.path,
  );
  final home = clean['HOME'];
  var cwd = '/';
  if (home != null && p.posix.isAbsolute(home)) {
    try {
      // Unlike _canonical, choosing a cwd must not fall back to a lexical path.
      final physicalHome = Directory(home).resolveSymbolicLinksSync();
      if (Directory(physicalHome).existsSync() &&
          physicalHome != root &&
          !p.posix.isWithin(root, physicalHome)) {
        cwd = physicalHome;
      }
    } on FileSystemException {
      // Missing, inaccessible or dangling HOME: start outside the AppImage.
    }
  }
  for (final command in commands) {
    if (command.isEmpty ||
        !p.posix.isAbsolute(command.first) ||
        !File(command.first).existsSync()) {
      continue;
    }
    try {
      final process = await Process.start(
        command.first,
        [...command.skip(1), uri.toString()],
        environment: clean,
        includeParentEnvironment: false,
        workingDirectory: cwd,
        runInShell: false,
      );
      unawaited(process.stdin.close().catchError((Object _) {}));
      // Drain without retaining arbitrary browser output. A browser may inherit
      // the pipes after the opener exits; never await those streams to finish.
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      return await process.exitCode.timeout(timeout, onTimeout: () => -1) == 0;
    } on ProcessException {
      return false;
    }
  }
  return false;
}
