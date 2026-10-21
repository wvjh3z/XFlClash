// Generate compiler input from the real injection function and runner call.
import 'dart:convert';
import 'dart:io';

import '../inject_desktop_brand.dart';

void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError('Expected fixture output directory');
  }
  final root = Directory(args.single)..createSync(recursive: true);
  final source = File('windows/runner/main.cpp').readAsStringSync();
  const names = {
    'brand_a': 'OmoFly',
    'brand_b': '袋鼠加速',
    'punctuation': r'袋鼠 "Pro" \u888B\path',
    'supplementary': '袋鼠 🦘',
    'hex_suffix': '袋鼠A9Fé',
  };
  final rows = <Map<String, Object>>[];
  for (final entry in names.entries) {
    final injected = injectWindowsTitle(source, entry.value);
    if (injectWindowsTitle(injected, entry.value) != injected) {
      throw StateError('Title injection is not idempotent');
    }
    final call = RegExp(
      r'^\s*if \(!window\.Create\(.*$',
      multiLine: true,
    ).allMatches(injected).single.group(0)!;
    if (call.codeUnits.any((unit) => unit >= 128)) {
      throw StateError('Injected title source must be ASCII');
    }
    File('${root.path}/${entry.key}.cpp').writeAsStringSync(_program(call));
    rows.add({'id': entry.key, 'utf16': entry.value.codeUnits});
  }
  // Old raw UTF-8 source: real compiler must expose its wrong CP1252 code units.
  final legacy = source.replaceFirst(
    RegExp(r'\bwindow\.Create\(\s*L"[^"]*"'),
    'window.Create(L"袋鼠加速"',
  );
  final call = RegExp(
    r'^\s*if \(!window\.Create\(.*$',
    multiLine: true,
  ).allMatches(legacy).single.group(0)!;
  File('${root.path}/legacy.cpp').writeAsStringSync(_program(call));
  File('${root.path}/manifest.json').writeAsStringSync(jsonEncode(rows));
}

String _program(String call) =>
    '''
#include <cstdio>
static_assert(sizeof(wchar_t) == 2, "Fixture requires Windows-width wchar_t");
struct Window {
  bool Create(const wchar_t* title, int, int) {
    for (const wchar_t* c = title; *c; ++c)
      std::printf("%04X ", static_cast<unsigned>(static_cast<unsigned short>(*c)));
    return true;
  }
};
int main() {
  Window window;
  int origin = 0, size = 0;
  $call
    return 1;
  }
  return 0;
}
''';
