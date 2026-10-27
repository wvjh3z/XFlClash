/// Parse decimal yuan without binary floating-point multiplication.
/// Reject fractions of a cent, exponents and values beyond exact double integers.
int? parseYuanCents(String text) {
  final value = text.trim();
  if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final fraction = parts.length == 1 ? '00' : parts[1].padRight(2, '0');
  final cents =
      BigInt.parse(parts[0]) * BigInt.from(100) + BigInt.parse(fraction);
  if (cents <= BigInt.zero || cents > BigInt.from(9007199254740991)) {
    return null;
  }
  return cents.toInt();
}
