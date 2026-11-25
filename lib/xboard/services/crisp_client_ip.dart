import 'dart:io';

import 'exit_ip_probe.dart';

/// Optional Crisp Bot input: a confirmed mainland public IPv4 exit only.
/// Never substitute a locale, a local interface address, or an IPv6 address.
String? crispClientIp(XbExitIpResult? result) {
  if (result == null || result.countryCode != 'CN') return null;
  final ip = InternetAddress.tryParse(result.ip);
  if (ip == null || ip.type != InternetAddressType.IPv4 || ip.address != result.ip) return null;
  final b = ip.rawAddress;
  final a = b[0], n = b[1], c = b[2];
  if (a == 0 || a == 10 || a == 127 || a >= 224 ||
      (a == 100 && n >= 64 && n <= 127) || (a == 169 && n == 254) ||
      (a == 172 && n >= 16 && n <= 31) ||
      (a == 192 && (n == 168 || (n == 0 && (c == 0 || c == 2)) || (n == 88 && c == 99))) ||
      (a == 198 && (n == 18 || n == 19 || (n == 51 && c == 100))) ||
      (a == 203 && n == 0 && c == 113)) {
    return null;
  }
  return ip.address;
}
