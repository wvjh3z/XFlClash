import 'package:fl_clash/xboard/services/core_startup_report_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late String? stored;
  late bool writable;

  CoreStartupReportBudget newBudget() => CoreStartupReportBudget(
    read: () async => stored,
    write: (value) async {
      if (!writable) return false;
      stored = value;
      return true;
    },
    now: () => now,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 22);
    stored = null;
    writable = true;
  });

  test('serializes duplicate and distinct failures and caps the install', () async {
    final budget = newBudget();
    expect(
      await Future.wait([
        for (final reason in ['bind', 'bind', 'spawn', 'exit', 'handshake'])
          budget.reserve(reason),
      ]),
      [true, false, true, true, false],
    );
    final restarted = newBudget();
    expect(await restarted.reserve('bind'), isFalse);
    expect(await restarted.reserve('handshake'), isFalse);
  });

  test('rolls 24 hours from each reservation and resists clock rollback', () async {
    final budget = newBudget();
    expect(await budget.reserve('bind'), isTrue);
    now = now.add(const Duration(hours: 1));
    expect(await budget.reserve('spawn'), isTrue);
    expect(await budget.reserve('exit'), isTrue);
    now = now.subtract(const Duration(hours: 2));
    expect(await newBudget().reserve('handshake'), isFalse);
    now = now.add(const Duration(hours: 25));
    final restarted = newBudget();
    expect(await restarted.reserve('handshake'), isTrue);
    expect(await restarted.reserve('bind'), isFalse);
  });

  test('corruption and failed writes never authorize a send', () async {
    stored = '{invalid';
    final budget = newBudget();
    expect(await budget.reserve('bind'), isFalse);
    expect(stored, '{invalid');
    stored = null;
    writable = false;
    expect(await budget.reserve('bind'), isFalse);
    expect(stored, isNull);
    writable = true;
    expect(await budget.reserve('bind'), isTrue);
  });
}
