import 'dart:convert';

/// A rolling limit on attempted sends, not on successful delivery. Reserving
/// before sending keeps crashes, ordinary restarts and transport errors from
/// refilling the budget. The desktop main process already has a single lock.
final class CoreStartupReportBudget {
  CoreStartupReportBudget({
    required Future<String?> Function() read,
    required Future<bool> Function(String) write,
    DateTime Function()? now,
  }) : _read = read,
       _write = write,
       _now = now ?? DateTime.now;

  static const _window = Duration(hours: 24);
  static const _maxReports = 3;
  final Future<String?> Function() _read;
  final Future<bool> Function(String) _write;
  final DateTime Function() _now;
  Future<void> _pending = Future.value();
  Map<String, int>? _lastReports;

  Future<bool> reserve(String reason) {
    final next = _pending.then((_) => _reserve(reason));
    _pending = next.then<void>((_) {});
    return next;
  }

  Future<bool> _reserve(String reason) async {
    try {
      final lastReports = _lastReports ??= _decode(await _read());
      final now = _now().millisecondsSinceEpoch;
      final cutoff = now - _window.inMilliseconds;
      // Future timestamps (wall clock was set back) stay in the budget.
      final active = {
        for (final entry in lastReports.entries)
          if (entry.value > cutoff) entry.key: entry.value,
      };
      if (active.containsKey(reason) || active.length >= _maxReports) {
        return false;
      }
      active[reason] = now;
      if (!await _write(jsonEncode(active))) return false;
      _lastReports = active;
      return true;
    } catch (_) {
      // An unreadable, malformed or unwritable ledger never opens the gate.
      return false;
    }
  }

  static Map<String, int> _decode(String? raw) {
    if (raw == null) return {};
    if (raw.length > 512) throw const FormatException();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded.length > _maxReports) {
      throw const FormatException();
    }
    return {for (final entry in decoded.entries) entry.key: entry.value as int};
  }
}
