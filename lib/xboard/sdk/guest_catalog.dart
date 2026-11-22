import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpStatus;

import 'package:dio/dio.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show PlanModel;

import '../models/plan_item.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../services/bounded_response_reader.dart';
import '../services/xboard_release_dio.dart';

/// Public plan reads have no dependency on the authenticated account catalog.
abstract interface class XboardGuestCatalogControl {
  Future<XbResult<List<PlanItem>>> getGuestCatalog();
}

const _guestPath = ['api', 'v1', 'guest', 'plan', 'fetch'];
const _maxCatalogBytes = 1024 * 1024;
const _priceFields = [
  'month_price',
  'quarter_price',
  'half_year_price',
  'year_price',
  'two_year_price',
  'three_year_price',
  'onetime_price',
  'reset_price',
];

/// Use only the configured brand API base, never a host from a plan or reply.
/// Own a fresh anonymous client: no SDK headers, TokenManager, or cookies.
Future<XbResult<List<PlanItem>>> loadGuestCatalog(
  String? brandApiBase,
  PlanItem Function(PlanModel) mapPlan, {
  HttpClientAdapter? testTransport,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final url = _catalogUrl(brandApiBase);
  if (url == null) {
    return const XbFailure(XbUnexpected('guestCatalog', '商店服务地址不可用'));
  }
  final dio = buildReleasedIsolatedDio(timeout: timeout);
  final token = CancelToken();
  try {
    if (testTransport != null) {
      dio.httpClientAdapter.close(force: true);
      dio.httpClientAdapter = testTransport;
    }
    dio.options.followRedirects = false;
    dio.options.headers['Accept'] = 'application/json';
    final response = await readBoundedResponse(
      dio,
      url,
      maxBytes: _maxCatalogBytes,
      cancelToken: token,
      sendTimeout: timeout,
      receiveTimeout: timeout,
    ).timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      return XbFailure(
        XbServer(response.statusCode ?? 0, '加载公开套餐失败'),
      );
    }
    final bytes = response.data;
    if (bytes == null) throw const FormatException('Missing catalog');
    return XbSuccess(_decodeCatalog(utf8.decode(bytes), mapPlan));
  } on TimeoutException {
    return const XbFailure(XbNetwork(XbNetworkKind.timeout, '加载公开套餐超时'));
  } on DioException catch (error) {
    final kind = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => XbNetworkKind.timeout,
      _ => XbNetworkKind.connectionFailed,
    };
    return XbFailure(XbNetwork(kind, '加载公开套餐失败'));
  } on Object {
    return const XbFailure(XbUnexpected('guestCatalog', '公开套餐响应无效'));
  } finally {
    token.cancel('Guest catalog request finished');
    dio.close(force: true);
  }
}

Uri? _catalogUrl(String? base) {
  final uri = Uri.tryParse(base?.trim() ?? '');
  if (uri == null ||
      !uri.isScheme('https') ||
      uri.host.isEmpty ||
      uri.authority.contains('@') ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port <= 0 ||
      uri.port > 65535) {
    return null;
  }
  final prefix = uri.pathSegments.toList();
  while (prefix.isNotEmpty && prefix.last.isEmpty) {
    prefix.removeLast();
  }
  return uri.replace(pathSegments: [...prefix, ..._guestPath]);
}

List<PlanItem> _decodeCatalog(
  String source,
  PlanItem Function(PlanModel) mapPlan,
) {
  final Object? payload = jsonDecode(source);
  if (payload is! Map<String, dynamic> ||
      payload['status'] != 'success' ||
      payload['data'] is! List<dynamic>) {
    throw const FormatException('Invalid catalog envelope');
  }
  final data = payload['data'] as List<dynamic>;
  final plans = <PlanItem>[];
  final ids = <int>{};
  for (final Object? item in data) {
    if (item is! Map<String, dynamic> ||
        item['id'] is! int ||
        (item['id'] as int) <= 0 ||
        !ids.add(item['id'] as int) ||
        item['name'] is! String ||
        (item['name'] as String).trim().isEmpty ||
        item['transfer_enable'] is! num ||
        !(item['transfer_enable'] as num).isFinite ||
        (item['transfer_enable'] as num) < 0 ||
        !_isFlag(item['show']) ||
        !_isFlag(item['sell']) ||
        !_isFlag(item['renew'])) {
      throw const FormatException('Invalid plan');
    }
    for (final field in _priceFields) {
      final Object? value = item[field];
      if (value == null) continue;
      final amount = switch (value) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
      // PHP multiplies decimal yuan by 100 using floats, so allow near-cent
      // roundoff without guessing a sub-cent or otherwise invalid price.
      if (amount == null ||
          !amount.isFinite ||
          amount < 0 ||
          amount > 9007199254740991 ||
          (amount - amount.round()).abs() > 0.000001) {
        throw const FormatException('Invalid plan price');
      }
    }
    final model = PlanModel.fromJson(item);
    final capacity = model.capacityLimit;
    if (model.show &&
        model.sell == true &&
        (capacity == null || capacity is num && capacity > 0) &&
        model.hasPrice) {
      plans.add(mapPlan(model));
    }
  }
  return List.unmodifiable(plans);
}

bool _isFlag(Object? value) =>
    value is bool || value is int && (value == 0 || value == 1);
