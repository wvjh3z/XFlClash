// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../models/bootstrap_payload.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_BootstrapEndpoint _$BootstrapEndpointFromJson(Map<String, dynamic> json) =>
    _BootstrapEndpoint(
      url: json['url'] as String,
      region: json['region'] == null
          ? BootstrapRegion.unknown
          : _regionFromString(json['region'] as String?),
    );

Map<String, dynamic> _$BootstrapEndpointToJson(_BootstrapEndpoint instance) =>
    <String, dynamic>{
      'url': instance.url,
      'region': _regionToString(instance.region),
    };

_BootstrapPayload _$BootstrapPayloadFromJson(Map<String, dynamic> json) =>
    _BootstrapPayload(
      apiEndpoints: json['api_endpoints'] == null
          ? const <BootstrapEndpoint>[]
          : _endpointsFromJson(json['api_endpoints']),
      subscriptionEndpoints: json['subscription_endpoints'] == null
          ? const <BootstrapEndpoint>[]
          : _endpointsFromJson(json['subscription_endpoints']),
      nextBootstrapUrls:
          (json['next_bootstrap_urls'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
    );

Map<String, dynamic> _$BootstrapPayloadToJson(_BootstrapPayload instance) =>
    <String, dynamic>{
      'api_endpoints': instance.apiEndpoints,
      'subscription_endpoints': instance.subscriptionEndpoints,
      'next_bootstrap_urls': instance.nextBootstrapUrls,
    };
