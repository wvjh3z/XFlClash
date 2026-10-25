import 'dart:async';
import 'dart:io';

/// Wait for this exact process instance, never kill by executable name.
/// Arguments, including paths with spaces/quotes, are not interpolated as code.
const xbAppImageRestartScript = r'''
set -eu
set -f
parent=$1
started=$2
target=$3
ready=$4
control=${ready%/*}
sleep_command=$(command -v sleep)
remove_command=$(command -v rm)
printf 'ready\n' > "$ready"
remaining=60
while [ ! -f "$control/commit" ]; do
  [ -d "$control" ] && [ ! -f "$control/cancel" ] || exit 125
  [ "$remaining" -gt 0 ] || exit 124
  remaining=$((remaining - 1))
  "$sleep_command" 1
done
[ -d "$control" ] && [ ! -f "$control/cancel" ] || exit 125
printf 'accepted\n' > "$control/accepted"
remaining=60
while [ -r "/proc/$parent/stat" ]; do
  [ -d "$control" ] && [ ! -f "$control/cancel" ] || exit 125
  IFS= read -r stat < "/proc/$parent/stat" || break
  fields=${stat##*) }
  set -- $fields
  state=$1
  shift 19
  [ "$1" = "$started" ] || break
  [ "$state" != Z ] || break
  [ "$remaining" -gt 0 ] || exit 124
  remaining=$((remaining - 1))
  "$sleep_command" 1
done
[ -d "$control" ] && [ ! -f "$control/cancel" ] || exit 125
"$remove_command" -rf -- "$control"
exec "$target" </dev/null >/dev/null 2>&1
''';

class XbAppImageRestartTicket {
  XbAppImageRestartTicket(
    this.directory, {
    Process? process,
    this.timeout = const Duration(seconds: 5),
  }) : _process = process {
    if (process != null) {
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      _completion = process.exitCode.then(
        (code) {
          _exited = true;
          _status = code;
          return code;
        },
        onError: (Object error, StackTrace stack) {
          _exited = true;
          _status = -1;
          return -1;
        },
      );
    }
  }
  final Directory directory;
  final Process? _process;
  final Duration timeout;
  Future<int>? _completion;
  bool _exited = false;
  int? _status;
  String? _identity;
  bool _committed = false;
  bool _cancelled = false;

  Future<void> _ensureAlive(String phase) async {
    final process = _process;
    if (_cancelled || process == null || _exited) {
      throw StateError('AppImage waiter unavailable at $phase (exit=$_status)');
    }
    final ({String state, String started}) info;
    try {
      info = await _processInfo(process.pid);
    } on FileSystemException {
      throw StateError('AppImage waiter unavailable at $phase (exit=$_status)');
    }
    if (info.state == 'Z' ||
        info.state == 'X' ||
        (_identity != null && info.started != _identity)) {
      throw StateError('AppImage waiter exited at $phase');
    }
    _identity ??= info.started;
  }

  Future<void> _waitFor(String name) async {
    final clock = Stopwatch()..start();
    final marker = File('${directory.path}/$name');
    while (true) {
      await _ensureAlive(name);
      if (await marker.exists()) {
        if ((await marker.readAsString()).trim() != name) {
          throw StateError('Invalid AppImage waiter $name marker');
        }
        await _ensureAlive(name);
        return;
      }
      if (clock.elapsed >= timeout) {
        throw StateError('AppImage waiter timed out at $name');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> waitUntilReady() => _waitFor('ready');

  Future<void> commit() async {
    if (_committed) {
      await _ensureAlive('committed');
      return;
    }
    await _ensureAlive('commit');
    await File('${directory.path}/commit').writeAsString('commit');
    await _waitFor('accepted');
    _committed = true;
  }

  Future<void> cancel() async {
    _cancelled = true;
    if (await directory.exists()) {
      try {
        await File('${directory.path}/cancel').writeAsString('cancel');
      } catch (_) {
        /* Process ownership below is the fallback. */
      }
    }
    final completion = _completion;
    final process = _process;
    if (completion != null && process != null) {
      try {
        await completion.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Only this owned child handle; never signal a basename or user PID.
        process.kill(ProcessSignal.sigterm);
        try {
          await completion.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await completion.timeout(const Duration(seconds: 2));
        }
      }
    }
    // Keep cancellation evidence if a child could not be reaped above.
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<({String state, String started})> _processInfo(int processId) async {
  final stat = await File('/proc/$processId/stat').readAsString();
  final closing = stat.lastIndexOf(')');
  if (closing < 0) throw StateError('Invalid process identity');
  final fields = stat.substring(closing + 2).trim().split(RegExp(r'\s+'));
  if (fields.length < 20 || !RegExp(r'^\d+$').hasMatch(fields[19])) {
    throw StateError('Cannot identify AppImage process');
  }
  return (state: fields.first, started: fields[19]);
}

typedef XbRestartStarter =
    Future<Process> Function(
      List<String> arguments,
      Map<String, String> environment,
    );

Future<XbAppImageRestartTicket> xbPrepareAppImageRestart(
  String target, {
  XbRestartStarter? startProcess,
  Duration readinessTimeout = const Duration(seconds: 5),
}) async {
  final parent = await _processInfo(pid);
  final directory = await Directory.systemTemp.createTemp('xb-restart-');
  final ready = File('${directory.path}/ready');
  final environment = Map<String, String>.from(Platform.environment);
  final appDir = environment.remove('APPDIR');
  environment.remove('APPIMAGE');
  environment.remove('ARGV0');
  if (appDir != null && appDir.isNotEmpty) {
    for (final key in ['LD_LIBRARY_PATH', 'PATH']) {
      final value = environment[key];
      if (value != null) {
        environment[key] = value
            .split(':')
            .where((p) => p != appDir && !p.startsWith('$appDir/'))
            .join(':');
      }
    }
  }
  XbAppImageRestartTicket? ticket;
  try {
    final arguments = [
      '-c',
      xbAppImageRestartScript,
      'xb-appimage-restart',
      '$pid',
      parent.started,
      target,
      ready.path,
    ];
    final process =
        await (startProcess ??
            (args, env) => Process.start(
              '/bin/sh',
              args,
              environment: env,
              includeParentEnvironment: false,
              mode: ProcessStartMode.normal,
            ))(arguments, environment);
    ticket = XbAppImageRestartTicket(
      directory,
      process: process,
      timeout: readinessTimeout,
    );
    await ticket.waitUntilReady();
    return ticket;
  } catch (_) {
    if (ticket != null) {
      await ticket.cancel();
    } else if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    rethrow;
  }
}
