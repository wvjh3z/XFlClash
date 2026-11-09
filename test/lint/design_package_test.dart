import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _roots = ['lib', 'test', 'tool', 'plugins'];

const _forbiddenImports = <String, String>{
  'package:material_ui/':
      'widgets come from package:flutter/widgets.dart and components from '
      'prism_ui',
  'package:cupertino_ui/':
      'widgets come from package:flutter/widgets.dart and components from '
      'prism_ui',
  'package:flutter/material.dart':
      'widgets come from package:flutter/widgets.dart and components from '
      'prism_ui',
  'package:flutter/cupertino.dart':
      'widgets come from package:flutter/widgets.dart and components from '
      'prism_ui',
};

const _generatedL10n = ['lib/l10n/l10n.dart', 'lib/l10n/intl/'];

// These tests exercise legacy theme/localizations and the Flutter HTML renderer
// used by the approved compatibility layer. Other direct design imports stay banned.
const _legacyCompatibilityTests = {
  'test/xboard/widgets/material_ui_bridge_test.dart',
  'test/xboard/widgets/prism_material_host_test.dart',
  'test/xboard/widgets/xb_html_contrast_test.dart',
};

bool _isApprovedBrandImport(String path, String packagePrefix) {
  if (packagePrefix == 'package:material_ui/') {
    return path.startsWith('lib/xboard/') ||
        path.startsWith('test/xboard/') ||
        path == 'lib/application.dart';
  }
  return packagePrefix == 'package:flutter/material.dart' &&
      _legacyCompatibilityTests.contains(path);
}

bool _isGenerated(String path) {
  return path.contains('/generated/') ||
      path.endsWith('.g.dart') ||
      path.endsWith('.freezed.dart') ||
      _generatedL10n.any(path.startsWith);
}

List<String> _findForbiddenImports(Directory project) {
  final offenders = <String>[];

  for (final root in _roots) {
    final directory = Directory(p.join(project.path, root));
    if (!directory.existsSync()) {
      fail('$root no longer exists; update _roots.');
    }
    for (final entity in directory.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final relative = p.posix.joinAll(
        p.split(p.relative(entity.path, from: project.path)),
      );
      if (_isGenerated(relative)) {
        continue;
      }
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (!line.startsWith('import ') && !line.startsWith('export ')) {
          continue;
        }
        for (final entry in _forbiddenImports.entries) {
          if (_isApprovedBrandImport(relative, entry.key)) {
            continue;
          }
          if (line.contains("'${entry.key}") ||
              line.contains('"${entry.key}')) {
            offenders.add('$relative:${i + 1} — ${entry.value}');
          }
        }
      }
    }
  }

  return offenders;
}

Directory _fixture(Map<String, String> imports) {
  final directory = Directory.systemTemp.createTempSync('design-import-guard-');
  addTearDown(() => directory.deleteSync(recursive: true));
  for (final root in _roots) {
    Directory(p.join(directory.path, root)).createSync();
  }
  for (final entry in imports.entries) {
    final file = File(p.joinAll([directory.path, ...entry.key.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync("import '${entry.value}';\n");
  }
  return directory;
}

void main() {
  test('design imports stay within the approved brand compatibility scope', () {
    final offenders = _findForbiddenImports(Directory.current);
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('accepts brand material_ui and explicit legacy bridge controls', () {
    final project = _fixture({
      'lib/application.dart': 'package:material_ui/material_ui.dart',
      'lib/xboard/widgets/example.dart': 'package:material_ui/material_ui.dart',
      'test/xboard/example_test.dart': 'package:material_ui/material_ui.dart',
      for (final path in _legacyCompatibilityTests)
        path: 'package:flutter/material.dart',
      'lib/views/base.dart': 'package:prism_ui/prism_ui.dart',
      'lib/widgets/base.dart': 'package:flutter/widgets.dart',
    });
    expect(_findForbiddenImports(project), isEmpty);
  });

  test('rejects base imports, prefix lookalikes and unapproved design libraries', () {
    final forbidden = {
      'lib/views/base.dart': 'package:material_ui/material_ui.dart',
      'lib/xboard_extra/example.dart': 'package:material_ui/material_ui.dart',
      'test/widgets/base_test.dart': 'package:material_ui/material_ui.dart',
      'plugins/example/lib/widget.dart': 'package:material_ui/material_ui.dart',
      'lib/application.dart': 'package:flutter/material.dart',
      'test/xboard/other_test.dart': 'package:flutter/material.dart',
      'lib/xboard/widgets/legacy.dart': 'package:flutter/material.dart',
      'lib/xboard/widgets/cupertino.dart': 'package:flutter/cupertino.dart',
      'lib/xboard/widgets/cupertino_package.dart': 'package:cupertino_ui/cupertino_ui.dart',
    };
    final offenders = _findForbiddenImports(_fixture(forbidden));
    expect(offenders, hasLength(forbidden.length));
    for (final path in forbidden.keys) {
      expect(offenders.where((entry) => entry.startsWith('$path:1 ')), hasLength(1));
    }
  });

  test('legacy bridge exceptions still exist and exercise the legacy package', () {
    for (final path in _legacyCompatibilityTests) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: 'Remove stale exception: $path');
      expect(file.readAsStringSync(), contains('package:flutter/material.dart'));
    }
  });
}
