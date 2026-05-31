// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../models/bootstrap_envelope.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$BootstrapEnvelope {

@JsonKey(name: 'schema_version') int get schemaVersion; String get encrypted;
/// Create a copy of BootstrapEnvelope
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BootstrapEnvelopeCopyWith<BootstrapEnvelope> get copyWith => _$BootstrapEnvelopeCopyWithImpl<BootstrapEnvelope>(this as BootstrapEnvelope, _$identity);

  /// Serializes this BootstrapEnvelope to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BootstrapEnvelope&&(identical(other.schemaVersion, schemaVersion) || other.schemaVersion == schemaVersion)&&(identical(other.encrypted, encrypted) || other.encrypted == encrypted));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,schemaVersion,encrypted);

@override
String toString() {
  return 'BootstrapEnvelope(schemaVersion: $schemaVersion, encrypted: $encrypted)';
}


}

/// @nodoc
abstract mixin class $BootstrapEnvelopeCopyWith<$Res>  {
  factory $BootstrapEnvelopeCopyWith(BootstrapEnvelope value, $Res Function(BootstrapEnvelope) _then) = _$BootstrapEnvelopeCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'schema_version') int schemaVersion, String encrypted
});




}
/// @nodoc
class _$BootstrapEnvelopeCopyWithImpl<$Res>
    implements $BootstrapEnvelopeCopyWith<$Res> {
  _$BootstrapEnvelopeCopyWithImpl(this._self, this._then);

  final BootstrapEnvelope _self;
  final $Res Function(BootstrapEnvelope) _then;

/// Create a copy of BootstrapEnvelope
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? schemaVersion = null,Object? encrypted = null,}) {
  return _then(_self.copyWith(
schemaVersion: null == schemaVersion ? _self.schemaVersion : schemaVersion // ignore: cast_nullable_to_non_nullable
as int,encrypted: null == encrypted ? _self.encrypted : encrypted // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [BootstrapEnvelope].
extension BootstrapEnvelopePatterns on BootstrapEnvelope {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BootstrapEnvelope value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BootstrapEnvelope() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BootstrapEnvelope value)  $default,){
final _that = this;
switch (_that) {
case _BootstrapEnvelope():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BootstrapEnvelope value)?  $default,){
final _that = this;
switch (_that) {
case _BootstrapEnvelope() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'schema_version')  int schemaVersion,  String encrypted)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BootstrapEnvelope() when $default != null:
return $default(_that.schemaVersion,_that.encrypted);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'schema_version')  int schemaVersion,  String encrypted)  $default,) {final _that = this;
switch (_that) {
case _BootstrapEnvelope():
return $default(_that.schemaVersion,_that.encrypted);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'schema_version')  int schemaVersion,  String encrypted)?  $default,) {final _that = this;
switch (_that) {
case _BootstrapEnvelope() when $default != null:
return $default(_that.schemaVersion,_that.encrypted);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BootstrapEnvelope implements BootstrapEnvelope {
  const _BootstrapEnvelope({@JsonKey(name: 'schema_version') required this.schemaVersion, required this.encrypted});
  factory _BootstrapEnvelope.fromJson(Map<String, dynamic> json) => _$BootstrapEnvelopeFromJson(json);

@override@JsonKey(name: 'schema_version') final  int schemaVersion;
@override final  String encrypted;

/// Create a copy of BootstrapEnvelope
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BootstrapEnvelopeCopyWith<_BootstrapEnvelope> get copyWith => __$BootstrapEnvelopeCopyWithImpl<_BootstrapEnvelope>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BootstrapEnvelopeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BootstrapEnvelope&&(identical(other.schemaVersion, schemaVersion) || other.schemaVersion == schemaVersion)&&(identical(other.encrypted, encrypted) || other.encrypted == encrypted));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,schemaVersion,encrypted);

@override
String toString() {
  return 'BootstrapEnvelope(schemaVersion: $schemaVersion, encrypted: $encrypted)';
}


}

/// @nodoc
abstract mixin class _$BootstrapEnvelopeCopyWith<$Res> implements $BootstrapEnvelopeCopyWith<$Res> {
  factory _$BootstrapEnvelopeCopyWith(_BootstrapEnvelope value, $Res Function(_BootstrapEnvelope) _then) = __$BootstrapEnvelopeCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'schema_version') int schemaVersion, String encrypted
});




}
/// @nodoc
class __$BootstrapEnvelopeCopyWithImpl<$Res>
    implements _$BootstrapEnvelopeCopyWith<$Res> {
  __$BootstrapEnvelopeCopyWithImpl(this._self, this._then);

  final _BootstrapEnvelope _self;
  final $Res Function(_BootstrapEnvelope) _then;

/// Create a copy of BootstrapEnvelope
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? schemaVersion = null,Object? encrypted = null,}) {
  return _then(_BootstrapEnvelope(
schemaVersion: null == schemaVersion ? _self.schemaVersion : schemaVersion // ignore: cast_nullable_to_non_nullable
as int,encrypted: null == encrypted ? _self.encrypted : encrypted // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
