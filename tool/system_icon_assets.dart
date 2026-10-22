// Validated, pre-rendered brand resources. No browser runs during a build.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _iconFiles = {
  'windows/status_1.ico',
  'windows/status_2.ico',
  'windows/status_3.ico',
  'linux/status_1.png',
  'linux/status_2.png',
  'linux/status_3.png',
  'macos/status_1.png',
  'android/drawable/xb_brand_system_icon.png',
  'android/drawable-hdpi/xb_brand_system_icon.png',
  'android/drawable-xhdpi/xb_brand_system_icon.png',
  'android/drawable-xxhdpi/xb_brand_system_icon.png',
  'android/drawable-xxxhdpi/xb_brand_system_icon.png',
};
const _icoSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
const _badgeColors = {
  'status_1': '#E5A14B',
  'status_2': '#12B8A6',
  'status_3': '#4B8FE8',
};

class SystemIconAssets {
  SystemIconAssets._(this.flavor, this.files, this.manifest);

  final String flavor;
  final Map<String, Uint8List> files;
  final Map<String, dynamic> manifest;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('Invalid system icon manifest schema');
  }
  return value;
}

File _safeFile(String root, String relative, {bool allowMissing = false}) {
  final absoluteRoot = p.normalize(p.absolute(root));
  final target = p.normalize(p.join(absoluteRoot, relative));
  if (p.isAbsolute(relative) ||
      !p.isWithin(absoluteRoot, target) ||
      p.split(relative).contains('..')) {
    throw const FormatException('Invalid system icon path');
  }
  var current = absoluteRoot;
  final parts = p.split(p.relative(target, from: absoluteRoot));
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    current = p.join(current, part);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (!allowMissing && type == FileSystemEntityType.notFound) ||
        (type != FileSystemEntityType.notFound &&
            type !=
                (index == parts.length - 1
                    ? FileSystemEntityType.file
                    : FileSystemEntityType.directory))) {
      throw const FormatException('System icon path is missing or invalid');
    }
  }
  return File(target);
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

(int, int) _pngSize(Uint8List bytes, [int offset = 0, int? length]) {
  final available = length ?? bytes.length - offset;
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (available < 24 ||
      offset < 0 ||
      offset + available > bytes.length ||
      !List.generate(
        8,
        (i) => bytes[offset + i],
      ).asMap().entries.every((e) => e.value == signature[e.key]) ||
      ascii.decode(bytes.sublist(offset + 12, offset + 16)) != 'IHDR') {
    throw const FormatException('Invalid system icon PNG');
  }
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(offset + 16), data.getUint32(offset + 20));
}

void _validateImage(String path, Uint8List bytes, Map<String, dynamic> info) {
  final width = info['width'];
  final height = info['height'];
  if (width is! int || height is! int || width < 1 || height < 1) {
    throw const FormatException('Invalid system icon dimensions');
  }
  if (path.endsWith('.png')) {
    final expectedSize = path.startsWith('linux/')
        ? 108
        : path.startsWith('macos/')
        ? 128
        : const {
            'drawable': 24,
            'drawable-hdpi': 36,
            'drawable-xhdpi': 48,
            'drawable-xxhdpi': 72,
            'drawable-xxxhdpi': 96,
          }[path.split('/')[1]];
    if (width != expectedSize ||
        height != expectedSize ||
        _pngSize(bytes) != (width, height)) {
      throw const FormatException('System icon PNG dimensions changed');
    }
    return;
  }
  if (bytes.length < 6 + _icoSizes.length * 16) {
    throw const FormatException('Invalid system icon ICO');
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint16(0, Endian.little) != 0 ||
      data.getUint16(2, Endian.little) != 1 ||
      data.getUint16(4, Endian.little) != _icoSizes.length ||
      jsonEncode(info['sizes']) != jsonEncode(_icoSizes) ||
      width != 256 ||
      height != 256) {
    throw const FormatException('Invalid system icon ICO directory');
  }
  var expectedOffset = 6 + _icoSizes.length * 16;
  for (var index = 0; index < _icoSizes.length; index++) {
    final directory = 6 + index * 16;
    final frameWidth = bytes[directory] == 0 ? 256 : bytes[directory];
    final frameHeight = bytes[directory + 1] == 0 ? 256 : bytes[directory + 1];
    final size = data.getUint32(directory + 8, Endian.little);
    final offset = data.getUint32(directory + 12, Endian.little);
    if (frameWidth != _icoSizes[index] ||
        frameHeight != _icoSizes[index] ||
        offset != expectedOffset ||
        size < 24 ||
        offset + size > bytes.length ||
        _pngSize(bytes, offset, size) != (frameWidth, frameHeight)) {
      throw const FormatException('Invalid system icon ICO frame');
    }
    expectedOffset += size;
  }
  if (expectedOffset != bytes.length) {
    throw const FormatException('Unexpected system icon ICO data');
  }
}

Future<SystemIconAssets> loadSystemIconAssets({
  required String projectRoot,
  required String flavor,
}) async {
  if (!{'brand_a', 'brand_b'}.contains(flavor)) {
    throw const FormatException('Unsupported system icon brand');
  }
  final directory = 'flavors/$flavor/system_icons';
  final manifest = _object(
    jsonDecode(
      _safeFile(projectRoot, '$directory/manifest.json').readAsStringSync(),
    ),
    {'schema', 'brand', 'source', 'badge_colors', 'files'},
  );
  if (manifest['schema'] != 1 || manifest['brand'] != flavor) {
    throw const FormatException('System icon brand or schema changed');
  }
  final source = _object(manifest['source'], {
    'color_sha256',
    'monochrome_sha256',
  });
  final colors = _object(manifest['badge_colors'], _badgeColors.keys.toSet());
  if (!_badgeColors.entries.every((e) => colors[e.key] == e.value)) {
    throw const FormatException('System icon status colors changed');
  }
  final color = _safeFile(
    projectRoot,
    'flavors/$flavor/assets/icons/$flavor.png',
  );
  final monochrome = _safeFile(projectRoot, '$directory/monochrome.svg');
  if (_digest(color.readAsBytesSync()) != source['color_sha256'] ||
      _digest(monochrome.readAsBytesSync()) != source['monochrome_sha256']) {
    throw const FormatException(
      'Brand icon source changed; regenerate system icons',
    );
  }
  final descriptions = _object(manifest['files'], _iconFiles);
  final files = <String, Uint8List>{};
  for (final relative in _iconFiles) {
    final info = _object(descriptions[relative], {
      'sha256',
      'bytes',
      'width',
      'height',
      if (relative.endsWith('.ico')) 'sizes',
    });
    final bytes = _safeFile(
      projectRoot,
      '$directory/$relative',
    ).readAsBytesSync();
    if (bytes.length != info['bytes'] || _digest(bytes) != info['sha256']) {
      throw const FormatException('System icon asset integrity check failed');
    }
    _validateImage(relative, bytes, info);
    files[relative] = bytes;
  }
  return SystemIconAssets._(
    flavor,
    Map.unmodifiable(files),
    Map.unmodifiable(manifest),
  );
}

Map<String, Uint8List> desktopSystemIconWrites(
  SystemIconAssets assets, {
  required String platform,
}) {
  if (!{'windows', 'linux', 'macos'}.contains(platform)) {
    throw const FormatException('Unsupported desktop system icon platform');
  }
  final extension = platform == 'windows' ? 'ico' : 'png';
  final directory = platform == 'linux' ? 'unix' : platform;
  final states = platform == 'macos' ? [1, 4] : [1, 2, 3, 4];
  final scales = platform == 'windows' ? [''] : ['', '2.0x/', '3.0x/', '4.0x/'];
  return {
    for (final state in states)
      for (final scale in scales)
        'assets/images/tray/$directory/${scale}status_$state.$extension': assets
            .files['$platform/status_${state == 4 ? 1 : state}.$extension']!,
  };
}

var _writeSerial = 0;

void applySystemIconWrites({
  required String projectRoot,
  required Map<String, Uint8List> writes,
  bool dryRun = false,
}) {
  final allowed = {
    for (final platform in ['windows', 'unix', 'macos'])
      for (final state in platform == 'macos' ? [1, 4] : [1, 2, 3, 4])
        for (final scale
            in platform == 'windows' ? [''] : ['', '2.0x/', '3.0x/', '4.0x/'])
          'assets/images/tray/$platform/${scale}status_$state.${platform == 'windows' ? 'ico' : 'png'}',
  };
  if (!writes.keys.every(allowed.contains)) {
    throw const FormatException('Invalid system icon destination');
  }
  final targets = {
    for (final relative in writes.keys)
      relative: _safeFile(projectRoot, relative, allowMissing: true),
  };
  if (dryRun) return;
  for (final entry in writes.entries) {
    final target = targets[entry.key]!;
    if (target.existsSync() &&
        _digest(target.readAsBytesSync()) == _digest(entry.value)) {
      continue;
    }
    target.parent.createSync(recursive: true);
    final staged = File('${target.path}.tmp-$pid-${_writeSerial++}');
    try {
      staged.writeAsBytesSync(entry.value, flush: true);
      staged.renameSync(target.path);
    } finally {
      if (staged.existsSync()) staged.deleteSync();
    }
  }
}
