/// Normalize dropdown choices and submission checks through one policy.
List<String> xbEmailSuffixes(List<String> suffixes) {
  final choices = <String>{};
  for (final raw in suffixes) {
    final value = raw.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (value.isNotEmpty && !RegExp(r'[\s\x00-\x1f\x7f@]').hasMatch(value)) {
      choices.add(value);
    }
  }
  return choices.toList(growable: false);
}

String? xbSelectedEmailSuffix(List<String> suffixes, String? selected) {
  final choices = xbEmailSuffixes(suffixes);
  final value = selected?.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  return choices.contains(value) ? value : choices.firstOrNull;
}

/// Preserve complete addresses. A whitelist never silently rewrites a domain.
String? xbComposeEmail(String input, List<String> suffixes, String? selected) {
  final text = input.trim();
  final choices = xbEmailSuffixes(suffixes);
  final suffix = xbSelectedEmailSuffix(choices, selected);
  final email = text.contains('@') || suffix == null ? text : '$text@$suffix';
  if (!RegExp(r'^[^\s\x00-\x1f\x7f@]+@[^\s\x00-\x1f\x7f@]+$').hasMatch(email)) { return null; }
  final domain = email.substring(email.lastIndexOf('@') + 1).toLowerCase();
  if (choices.isNotEmpty && !choices.contains(domain)) return null;
  return email;
}

String xbEmailValidationMessage(List<String> suffixes) {
  final choices = xbEmailSuffixes(suffixes);
  return choices.isEmpty
      ? '请输入完整有效的邮箱地址'
      : '请输入有效邮箱，允许的后缀：${choices.map((s) => '@$s').join('、')}';
}
