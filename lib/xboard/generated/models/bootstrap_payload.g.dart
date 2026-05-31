// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../models/bootstrap_payload.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_BootstrapPayload _$BootstrapPayloadFromJson(Map<String, dynamic> json) =>
    _BootstrapPayload(
      apiEndpoints:
          (json['api_endpoints'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
      subscriptionEndpoints:
          (json['subscription_endpoints'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
    );

Map<String, dynamic> _$BootstrapPayloadToJson(_BootstrapPayload instance) =>
    <String, dynamic>{
      'api_endpoints': instance.apiEndpoints,
      'subscription_endpoints': instance.subscriptionEndpoints,
    };
