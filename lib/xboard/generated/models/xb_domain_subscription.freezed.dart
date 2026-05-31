// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../models/xb_domain_subscription.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$XbDomainSubscription {

 String get email; String get uuid; String? get planName; int get totalBytes;// SubscriptionModel.transferEnable（字节 F408）
 int get usedBytes;// (u ?? 0) + (d ?? 0)（字节 R6.8）
 DateTime? get expiredAt;// null = 长期有效（一次性套餐 D51）
 DateTime? get nextResetAt;// null = 流量套餐/不重置（D51）
 int? get resetDay;// 月内重置日（F408 v1.13.0；≠ nextResetAt.day）
 int? get planId;
/// Create a copy of XbDomainSubscription
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$XbDomainSubscriptionCopyWith<XbDomainSubscription> get copyWith => _$XbDomainSubscriptionCopyWithImpl<XbDomainSubscription>(this as XbDomainSubscription, _$identity);

  /// Serializes this XbDomainSubscription to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is XbDomainSubscription&&(identical(other.email, email) || other.email == email)&&(identical(other.uuid, uuid) || other.uuid == uuid)&&(identical(other.planName, planName) || other.planName == planName)&&(identical(other.totalBytes, totalBytes) || other.totalBytes == totalBytes)&&(identical(other.usedBytes, usedBytes) || other.usedBytes == usedBytes)&&(identical(other.expiredAt, expiredAt) || other.expiredAt == expiredAt)&&(identical(other.nextResetAt, nextResetAt) || other.nextResetAt == nextResetAt)&&(identical(other.resetDay, resetDay) || other.resetDay == resetDay)&&(identical(other.planId, planId) || other.planId == planId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,email,uuid,planName,totalBytes,usedBytes,expiredAt,nextResetAt,resetDay,planId);

@override
String toString() {
  return 'XbDomainSubscription(email: $email, uuid: $uuid, planName: $planName, totalBytes: $totalBytes, usedBytes: $usedBytes, expiredAt: $expiredAt, nextResetAt: $nextResetAt, resetDay: $resetDay, planId: $planId)';
}


}

/// @nodoc
abstract mixin class $XbDomainSubscriptionCopyWith<$Res>  {
  factory $XbDomainSubscriptionCopyWith(XbDomainSubscription value, $Res Function(XbDomainSubscription) _then) = _$XbDomainSubscriptionCopyWithImpl;
@useResult
$Res call({
 String email, String uuid, String? planName, int totalBytes, int usedBytes, DateTime? expiredAt, DateTime? nextResetAt, int? resetDay, int? planId
});




}
/// @nodoc
class _$XbDomainSubscriptionCopyWithImpl<$Res>
    implements $XbDomainSubscriptionCopyWith<$Res> {
  _$XbDomainSubscriptionCopyWithImpl(this._self, this._then);

  final XbDomainSubscription _self;
  final $Res Function(XbDomainSubscription) _then;

/// Create a copy of XbDomainSubscription
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? email = null,Object? uuid = null,Object? planName = freezed,Object? totalBytes = null,Object? usedBytes = null,Object? expiredAt = freezed,Object? nextResetAt = freezed,Object? resetDay = freezed,Object? planId = freezed,}) {
  return _then(_self.copyWith(
email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,uuid: null == uuid ? _self.uuid : uuid // ignore: cast_nullable_to_non_nullable
as String,planName: freezed == planName ? _self.planName : planName // ignore: cast_nullable_to_non_nullable
as String?,totalBytes: null == totalBytes ? _self.totalBytes : totalBytes // ignore: cast_nullable_to_non_nullable
as int,usedBytes: null == usedBytes ? _self.usedBytes : usedBytes // ignore: cast_nullable_to_non_nullable
as int,expiredAt: freezed == expiredAt ? _self.expiredAt : expiredAt // ignore: cast_nullable_to_non_nullable
as DateTime?,nextResetAt: freezed == nextResetAt ? _self.nextResetAt : nextResetAt // ignore: cast_nullable_to_non_nullable
as DateTime?,resetDay: freezed == resetDay ? _self.resetDay : resetDay // ignore: cast_nullable_to_non_nullable
as int?,planId: freezed == planId ? _self.planId : planId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [XbDomainSubscription].
extension XbDomainSubscriptionPatterns on XbDomainSubscription {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _XbDomainSubscription value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _XbDomainSubscription() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _XbDomainSubscription value)  $default,){
final _that = this;
switch (_that) {
case _XbDomainSubscription():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _XbDomainSubscription value)?  $default,){
final _that = this;
switch (_that) {
case _XbDomainSubscription() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String email,  String uuid,  String? planName,  int totalBytes,  int usedBytes,  DateTime? expiredAt,  DateTime? nextResetAt,  int? resetDay,  int? planId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _XbDomainSubscription() when $default != null:
return $default(_that.email,_that.uuid,_that.planName,_that.totalBytes,_that.usedBytes,_that.expiredAt,_that.nextResetAt,_that.resetDay,_that.planId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String email,  String uuid,  String? planName,  int totalBytes,  int usedBytes,  DateTime? expiredAt,  DateTime? nextResetAt,  int? resetDay,  int? planId)  $default,) {final _that = this;
switch (_that) {
case _XbDomainSubscription():
return $default(_that.email,_that.uuid,_that.planName,_that.totalBytes,_that.usedBytes,_that.expiredAt,_that.nextResetAt,_that.resetDay,_that.planId);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String email,  String uuid,  String? planName,  int totalBytes,  int usedBytes,  DateTime? expiredAt,  DateTime? nextResetAt,  int? resetDay,  int? planId)?  $default,) {final _that = this;
switch (_that) {
case _XbDomainSubscription() when $default != null:
return $default(_that.email,_that.uuid,_that.planName,_that.totalBytes,_that.usedBytes,_that.expiredAt,_that.nextResetAt,_that.resetDay,_that.planId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _XbDomainSubscription extends XbDomainSubscription {
  const _XbDomainSubscription({required this.email, required this.uuid, this.planName, required this.totalBytes, required this.usedBytes, this.expiredAt, this.nextResetAt, this.resetDay, this.planId}): super._();
  factory _XbDomainSubscription.fromJson(Map<String, dynamic> json) => _$XbDomainSubscriptionFromJson(json);

@override final  String email;
@override final  String uuid;
@override final  String? planName;
@override final  int totalBytes;
// SubscriptionModel.transferEnable（字节 F408）
@override final  int usedBytes;
// (u ?? 0) + (d ?? 0)（字节 R6.8）
@override final  DateTime? expiredAt;
// null = 长期有效（一次性套餐 D51）
@override final  DateTime? nextResetAt;
// null = 流量套餐/不重置（D51）
@override final  int? resetDay;
// 月内重置日（F408 v1.13.0；≠ nextResetAt.day）
@override final  int? planId;

/// Create a copy of XbDomainSubscription
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$XbDomainSubscriptionCopyWith<_XbDomainSubscription> get copyWith => __$XbDomainSubscriptionCopyWithImpl<_XbDomainSubscription>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$XbDomainSubscriptionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _XbDomainSubscription&&(identical(other.email, email) || other.email == email)&&(identical(other.uuid, uuid) || other.uuid == uuid)&&(identical(other.planName, planName) || other.planName == planName)&&(identical(other.totalBytes, totalBytes) || other.totalBytes == totalBytes)&&(identical(other.usedBytes, usedBytes) || other.usedBytes == usedBytes)&&(identical(other.expiredAt, expiredAt) || other.expiredAt == expiredAt)&&(identical(other.nextResetAt, nextResetAt) || other.nextResetAt == nextResetAt)&&(identical(other.resetDay, resetDay) || other.resetDay == resetDay)&&(identical(other.planId, planId) || other.planId == planId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,email,uuid,planName,totalBytes,usedBytes,expiredAt,nextResetAt,resetDay,planId);

@override
String toString() {
  return 'XbDomainSubscription(email: $email, uuid: $uuid, planName: $planName, totalBytes: $totalBytes, usedBytes: $usedBytes, expiredAt: $expiredAt, nextResetAt: $nextResetAt, resetDay: $resetDay, planId: $planId)';
}


}

/// @nodoc
abstract mixin class _$XbDomainSubscriptionCopyWith<$Res> implements $XbDomainSubscriptionCopyWith<$Res> {
  factory _$XbDomainSubscriptionCopyWith(_XbDomainSubscription value, $Res Function(_XbDomainSubscription) _then) = __$XbDomainSubscriptionCopyWithImpl;
@override @useResult
$Res call({
 String email, String uuid, String? planName, int totalBytes, int usedBytes, DateTime? expiredAt, DateTime? nextResetAt, int? resetDay, int? planId
});




}
/// @nodoc
class __$XbDomainSubscriptionCopyWithImpl<$Res>
    implements _$XbDomainSubscriptionCopyWith<$Res> {
  __$XbDomainSubscriptionCopyWithImpl(this._self, this._then);

  final _XbDomainSubscription _self;
  final $Res Function(_XbDomainSubscription) _then;

/// Create a copy of XbDomainSubscription
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? email = null,Object? uuid = null,Object? planName = freezed,Object? totalBytes = null,Object? usedBytes = null,Object? expiredAt = freezed,Object? nextResetAt = freezed,Object? resetDay = freezed,Object? planId = freezed,}) {
  return _then(_XbDomainSubscription(
email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,uuid: null == uuid ? _self.uuid : uuid // ignore: cast_nullable_to_non_nullable
as String,planName: freezed == planName ? _self.planName : planName // ignore: cast_nullable_to_non_nullable
as String?,totalBytes: null == totalBytes ? _self.totalBytes : totalBytes // ignore: cast_nullable_to_non_nullable
as int,usedBytes: null == usedBytes ? _self.usedBytes : usedBytes // ignore: cast_nullable_to_non_nullable
as int,expiredAt: freezed == expiredAt ? _self.expiredAt : expiredAt // ignore: cast_nullable_to_non_nullable
as DateTime?,nextResetAt: freezed == nextResetAt ? _self.nextResetAt : nextResetAt // ignore: cast_nullable_to_non_nullable
as DateTime?,resetDay: freezed == resetDay ? _self.resetDay : resetDay // ignore: cast_nullable_to_non_nullable
as int?,planId: freezed == planId ? _self.planId : planId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

// dart format on
