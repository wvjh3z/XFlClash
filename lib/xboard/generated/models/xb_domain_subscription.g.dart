// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../models/xb_domain_subscription.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_XbDomainSubscription _$XbDomainSubscriptionFromJson(
  Map<String, dynamic> json,
) => _XbDomainSubscription(
  email: json['email'] as String,
  uuid: json['uuid'] as String,
  planName: json['planName'] as String?,
  totalBytes: (json['totalBytes'] as num).toInt(),
  usedBytes: (json['usedBytes'] as num).toInt(),
  expiredAt: json['expiredAt'] == null
      ? null
      : DateTime.parse(json['expiredAt'] as String),
  nextResetAt: json['nextResetAt'] == null
      ? null
      : DateTime.parse(json['nextResetAt'] as String),
  resetDay: (json['resetDay'] as num?)?.toInt(),
  planId: (json['planId'] as num?)?.toInt(),
);

Map<String, dynamic> _$XbDomainSubscriptionToJson(
  _XbDomainSubscription instance,
) => <String, dynamic>{
  'email': instance.email,
  'uuid': instance.uuid,
  'planName': instance.planName,
  'totalBytes': instance.totalBytes,
  'usedBytes': instance.usedBytes,
  'expiredAt': instance.expiredAt?.toIso8601String(),
  'nextResetAt': instance.nextResetAt?.toIso8601String(),
  'resetDay': instance.resetDay,
  'planId': instance.planId,
};
