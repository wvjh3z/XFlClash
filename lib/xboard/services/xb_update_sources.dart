import 'dart:math';

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;

/// 应用内下载和浏览器共用的更新候选：合法 HTTP(S) 地址，匹配地区优先。
///
/// 同一优先级保留服务端顺序；地区未知时不偏好任何标签。不修改清单。
List<String> xbSortedUpdateUrls(AppUpdateModel info) {
  final preferred = <String>[];
  final remaining = <String>[];
  final hasRegionPreference = info.region == 'cn' || info.region == 'overseas';

  for (final download in info.downloads) {
    final url = download.url.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty) {
      continue;
    }
    try {
      // Uri 会将 host 内原始空白转为百分号编码，解码后再验证。
      if (RegExp(
        r'[\s\x00-\x1f\x7f]',
      ).hasMatch(Uri.decodeComponent(uri.host))) {
        continue;
      }
    } on FormatException {
      continue;
    }
    if (hasRegionPreference && download.region == info.region) {
      preferred.add(url);
    } else {
      remaining.add(url);
    }
  }

  return [...preferred, ...remaining];
}

/// 按共用候选顺序交给外部下载入口，成功打开后停止；失败则尝试下一个。
Future<bool> xbOpenUpdateDownload(
  AppUpdateModel info, {
  required Future<bool> Function(Uri uri) open,
  List<String>? orderedUrls,
}) async {
  for (final url in orderedUrls ?? xbSortedUpdateUrls(info)) {
    try {
      if (await open(Uri.parse(url))) return true;
    } catch (_) {
      // 平台可能抛异常，也可能返回 false；两种情况都继续尝试后续源。
    }
  }
  return false;
}

/// Freeze one attempt's order; duplicate URLs are attempted only once.
/// Unknown location preserves the server order. Unknown mirror labels are last.
List<String> xbRandomizedUpdateUrls(
  AppUpdateModel info, {
  String? countryCode,
  Random? random,
}) {
  final region =
      countryCode != null && RegExp(r'^[a-zA-Z]{2}$').hasMatch(countryCode)
      ? (countryCode.toUpperCase() == 'CN' ? 'cn' : 'overseas')
      : info.region;
  final valid = xbSortedUpdateUrls(info).toSet();
  final seen = <String>{};
  final groups = <String, List<String>>{
    'cn': [],
    'overseas': [],
    'unknown': [],
  };
  final original = <String>[];
  for (final item in info.downloads) {
    final url = item.url.trim();
    if (!valid.contains(url) || !seen.add(url)) continue;
    original.add(url);
    groups[groups.containsKey(item.region) ? item.region : 'unknown']!.add(url);
  }
  if (region != 'cn' && region != 'overseas') return original;
  final rng = random ?? Random();
  for (final group in groups.values) {
    group.shuffle(rng);
  }
  return [
    ...groups[region]!,
    ...groups[region == 'cn' ? 'overseas' : 'cn']!,
    ...groups['unknown']!,
  ];
}
