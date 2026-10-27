import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/util/money_input.dart';

void main() {
  test('decimal cents remain exact', () {
    for (final pair in {
      '0.29': 29,
      '0.57': 57,
      '1.13': 113,
      '2.01': 201,
      '4.10': 410,
      '1': 100,
      ' 1.2 ': 120,
    }.entries) {
      expect(parseYuanCents(pair.key), pair.value);
    }
  });
  test('invalid or non-cent amounts rejected', () {
    for (final value in [
      '',
      'NaN',
      'Infinity',
      '0',
      '-1',
      '1.001',
      '1e3',
      '999999999999999999',
    ]) {
      expect(parseYuanCents(value), isNull, reason: value);
    }
  });
}
