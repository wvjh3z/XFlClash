// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../models/bootstrap_envelope.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_BootstrapEnvelope _$BootstrapEnvelopeFromJson(Map<String, dynamic> json) =>
    _BootstrapEnvelope(
      schemaVersion: (json['schema_version'] as num).toInt(),
      encrypted: json['encrypted'] as String,
    );

Map<String, dynamic> _$BootstrapEnvelopeToJson(_BootstrapEnvelope instance) =>
    <String, dynamic>{
      'schema_version': instance.schemaVersion,
      'encrypted': instance.encrypted,
    };
