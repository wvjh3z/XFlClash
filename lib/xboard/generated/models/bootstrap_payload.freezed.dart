// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../models/bootstrap_payload.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$BootstrapEndpoint {

 String get url;@JsonKey(fromJson: _regionFromString, toJson: _regionToString) BootstrapRegion get region;
/// Create a copy of BootstrapEndpoint
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BootstrapEndpointCopyWith<BootstrapEndpoint> get copyWith => _$BootstrapEndpointCopyWithImpl<BootstrapEndpoint>(this as BootstrapEndpoint, _$identity);

  /// Serializes this BootstrapEndpoint to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BootstrapEndpoint&&(identical(other.url, url) || other.url == url)&&(identical(other.region, region) || other.region == region));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,url,region);

@override
String toString() {
  return 'BootstrapEndpoint(url: $url, region: $region)';
}


}

/// @nodoc
abstract mixin class $BootstrapEndpointCopyWith<$Res>  {
  factory $BootstrapEndpointCopyWith(BootstrapEndpoint value, $Res Function(BootstrapEndpoint) _then) = _$BootstrapEndpointCopyWithImpl;
@useResult
$Res call({
 String url,@JsonKey(fromJson: _regionFromString, toJson: _regionToString) BootstrapRegion region
});




}
/// @nodoc
class _$BootstrapEndpointCopyWithImpl<$Res>
    implements $BootstrapEndpointCopyWith<$Res> {
  _$BootstrapEndpointCopyWithImpl(this._self, this._then);

  final BootstrapEndpoint _self;
  final $Res Function(BootstrapEndpoint) _then;

/// Create a copy of BootstrapEndpoint
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? url = null,Object? region = null,}) {
  return _then(_self.copyWith(
url: null == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String,region: null == region ? _self.region : region // ignore: cast_nullable_to_non_nullable
as BootstrapRegion,
  ));
}

}


/// Adds pattern-matching-related methods to [BootstrapEndpoint].
extension BootstrapEndpointPatterns on BootstrapEndpoint {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BootstrapEndpoint value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BootstrapEndpoint() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BootstrapEndpoint value)  $default,){
final _that = this;
switch (_that) {
case _BootstrapEndpoint():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BootstrapEndpoint value)?  $default,){
final _that = this;
switch (_that) {
case _BootstrapEndpoint() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String url, @JsonKey(fromJson: _regionFromString, toJson: _regionToString)  BootstrapRegion region)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BootstrapEndpoint() when $default != null:
return $default(_that.url,_that.region);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String url, @JsonKey(fromJson: _regionFromString, toJson: _regionToString)  BootstrapRegion region)  $default,) {final _that = this;
switch (_that) {
case _BootstrapEndpoint():
return $default(_that.url,_that.region);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String url, @JsonKey(fromJson: _regionFromString, toJson: _regionToString)  BootstrapRegion region)?  $default,) {final _that = this;
switch (_that) {
case _BootstrapEndpoint() when $default != null:
return $default(_that.url,_that.region);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BootstrapEndpoint extends BootstrapEndpoint {
  const _BootstrapEndpoint({required this.url, @JsonKey(fromJson: _regionFromString, toJson: _regionToString) this.region = BootstrapRegion.unknown}): super._();
  factory _BootstrapEndpoint.fromJson(Map<String, dynamic> json) => _$BootstrapEndpointFromJson(json);

@override final  String url;
@override@JsonKey(fromJson: _regionFromString, toJson: _regionToString) final  BootstrapRegion region;

/// Create a copy of BootstrapEndpoint
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BootstrapEndpointCopyWith<_BootstrapEndpoint> get copyWith => __$BootstrapEndpointCopyWithImpl<_BootstrapEndpoint>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BootstrapEndpointToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BootstrapEndpoint&&(identical(other.url, url) || other.url == url)&&(identical(other.region, region) || other.region == region));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,url,region);

@override
String toString() {
  return 'BootstrapEndpoint(url: $url, region: $region)';
}


}

/// @nodoc
abstract mixin class _$BootstrapEndpointCopyWith<$Res> implements $BootstrapEndpointCopyWith<$Res> {
  factory _$BootstrapEndpointCopyWith(_BootstrapEndpoint value, $Res Function(_BootstrapEndpoint) _then) = __$BootstrapEndpointCopyWithImpl;
@override @useResult
$Res call({
 String url,@JsonKey(fromJson: _regionFromString, toJson: _regionToString) BootstrapRegion region
});




}
/// @nodoc
class __$BootstrapEndpointCopyWithImpl<$Res>
    implements _$BootstrapEndpointCopyWith<$Res> {
  __$BootstrapEndpointCopyWithImpl(this._self, this._then);

  final _BootstrapEndpoint _self;
  final $Res Function(_BootstrapEndpoint) _then;

/// Create a copy of BootstrapEndpoint
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? url = null,Object? region = null,}) {
  return _then(_BootstrapEndpoint(
url: null == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String,region: null == region ? _self.region : region // ignore: cast_nullable_to_non_nullable
as BootstrapRegion,
  ));
}


}


/// @nodoc
mixin _$BootstrapPayload {

@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> get apiEndpoints;@JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> get subscriptionEndpoints;// R4.7 地址自举：下一代 bootstrap 分发地址（客户端拉取后缓存滚动）。
@JsonKey(name: 'next_bootstrap_urls') List<String> get nextBootstrapUrls;
/// Create a copy of BootstrapPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BootstrapPayloadCopyWith<BootstrapPayload> get copyWith => _$BootstrapPayloadCopyWithImpl<BootstrapPayload>(this as BootstrapPayload, _$identity);

  /// Serializes this BootstrapPayload to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BootstrapPayload&&const DeepCollectionEquality().equals(other.apiEndpoints, apiEndpoints)&&const DeepCollectionEquality().equals(other.subscriptionEndpoints, subscriptionEndpoints)&&const DeepCollectionEquality().equals(other.nextBootstrapUrls, nextBootstrapUrls));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(apiEndpoints),const DeepCollectionEquality().hash(subscriptionEndpoints),const DeepCollectionEquality().hash(nextBootstrapUrls));

@override
String toString() {
  return 'BootstrapPayload(apiEndpoints: $apiEndpoints, subscriptionEndpoints: $subscriptionEndpoints, nextBootstrapUrls: $nextBootstrapUrls)';
}


}

/// @nodoc
abstract mixin class $BootstrapPayloadCopyWith<$Res>  {
  factory $BootstrapPayloadCopyWith(BootstrapPayload value, $Res Function(BootstrapPayload) _then) = _$BootstrapPayloadCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> apiEndpoints,@JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> subscriptionEndpoints,@JsonKey(name: 'next_bootstrap_urls') List<String> nextBootstrapUrls
});




}
/// @nodoc
class _$BootstrapPayloadCopyWithImpl<$Res>
    implements $BootstrapPayloadCopyWith<$Res> {
  _$BootstrapPayloadCopyWithImpl(this._self, this._then);

  final BootstrapPayload _self;
  final $Res Function(BootstrapPayload) _then;

/// Create a copy of BootstrapPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? apiEndpoints = null,Object? subscriptionEndpoints = null,Object? nextBootstrapUrls = null,}) {
  return _then(_self.copyWith(
apiEndpoints: null == apiEndpoints ? _self.apiEndpoints : apiEndpoints // ignore: cast_nullable_to_non_nullable
as List<BootstrapEndpoint>,subscriptionEndpoints: null == subscriptionEndpoints ? _self.subscriptionEndpoints : subscriptionEndpoints // ignore: cast_nullable_to_non_nullable
as List<BootstrapEndpoint>,nextBootstrapUrls: null == nextBootstrapUrls ? _self.nextBootstrapUrls : nextBootstrapUrls // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [BootstrapPayload].
extension BootstrapPayloadPatterns on BootstrapPayload {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BootstrapPayload value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BootstrapPayload() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BootstrapPayload value)  $default,){
final _that = this;
switch (_that) {
case _BootstrapPayload():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BootstrapPayload value)?  $default,){
final _that = this;
switch (_that) {
case _BootstrapPayload() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson)  List<BootstrapEndpoint> apiEndpoints, @JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson)  List<BootstrapEndpoint> subscriptionEndpoints, @JsonKey(name: 'next_bootstrap_urls')  List<String> nextBootstrapUrls)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BootstrapPayload() when $default != null:
return $default(_that.apiEndpoints,_that.subscriptionEndpoints,_that.nextBootstrapUrls);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson)  List<BootstrapEndpoint> apiEndpoints, @JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson)  List<BootstrapEndpoint> subscriptionEndpoints, @JsonKey(name: 'next_bootstrap_urls')  List<String> nextBootstrapUrls)  $default,) {final _that = this;
switch (_that) {
case _BootstrapPayload():
return $default(_that.apiEndpoints,_that.subscriptionEndpoints,_that.nextBootstrapUrls);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson)  List<BootstrapEndpoint> apiEndpoints, @JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson)  List<BootstrapEndpoint> subscriptionEndpoints, @JsonKey(name: 'next_bootstrap_urls')  List<String> nextBootstrapUrls)?  $default,) {final _that = this;
switch (_that) {
case _BootstrapPayload() when $default != null:
return $default(_that.apiEndpoints,_that.subscriptionEndpoints,_that.nextBootstrapUrls);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BootstrapPayload extends BootstrapPayload {
  const _BootstrapPayload({@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson) final  List<BootstrapEndpoint> apiEndpoints = const <BootstrapEndpoint>[], @JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson) final  List<BootstrapEndpoint> subscriptionEndpoints = const <BootstrapEndpoint>[], @JsonKey(name: 'next_bootstrap_urls') final  List<String> nextBootstrapUrls = const <String>[]}): _apiEndpoints = apiEndpoints,_subscriptionEndpoints = subscriptionEndpoints,_nextBootstrapUrls = nextBootstrapUrls,super._();
  factory _BootstrapPayload.fromJson(Map<String, dynamic> json) => _$BootstrapPayloadFromJson(json);

 final  List<BootstrapEndpoint> _apiEndpoints;
@override@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> get apiEndpoints {
  if (_apiEndpoints is EqualUnmodifiableListView) return _apiEndpoints;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_apiEndpoints);
}

 final  List<BootstrapEndpoint> _subscriptionEndpoints;
@override@JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> get subscriptionEndpoints {
  if (_subscriptionEndpoints is EqualUnmodifiableListView) return _subscriptionEndpoints;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_subscriptionEndpoints);
}

// R4.7 地址自举：下一代 bootstrap 分发地址（客户端拉取后缓存滚动）。
 final  List<String> _nextBootstrapUrls;
// R4.7 地址自举：下一代 bootstrap 分发地址（客户端拉取后缓存滚动）。
@override@JsonKey(name: 'next_bootstrap_urls') List<String> get nextBootstrapUrls {
  if (_nextBootstrapUrls is EqualUnmodifiableListView) return _nextBootstrapUrls;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_nextBootstrapUrls);
}


/// Create a copy of BootstrapPayload
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BootstrapPayloadCopyWith<_BootstrapPayload> get copyWith => __$BootstrapPayloadCopyWithImpl<_BootstrapPayload>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BootstrapPayloadToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BootstrapPayload&&const DeepCollectionEquality().equals(other._apiEndpoints, _apiEndpoints)&&const DeepCollectionEquality().equals(other._subscriptionEndpoints, _subscriptionEndpoints)&&const DeepCollectionEquality().equals(other._nextBootstrapUrls, _nextBootstrapUrls));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_apiEndpoints),const DeepCollectionEquality().hash(_subscriptionEndpoints),const DeepCollectionEquality().hash(_nextBootstrapUrls));

@override
String toString() {
  return 'BootstrapPayload(apiEndpoints: $apiEndpoints, subscriptionEndpoints: $subscriptionEndpoints, nextBootstrapUrls: $nextBootstrapUrls)';
}


}

/// @nodoc
abstract mixin class _$BootstrapPayloadCopyWith<$Res> implements $BootstrapPayloadCopyWith<$Res> {
  factory _$BootstrapPayloadCopyWith(_BootstrapPayload value, $Res Function(_BootstrapPayload) _then) = __$BootstrapPayloadCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'api_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> apiEndpoints,@JsonKey(name: 'subscription_endpoints', fromJson: _endpointsFromJson) List<BootstrapEndpoint> subscriptionEndpoints,@JsonKey(name: 'next_bootstrap_urls') List<String> nextBootstrapUrls
});




}
/// @nodoc
class __$BootstrapPayloadCopyWithImpl<$Res>
    implements _$BootstrapPayloadCopyWith<$Res> {
  __$BootstrapPayloadCopyWithImpl(this._self, this._then);

  final _BootstrapPayload _self;
  final $Res Function(_BootstrapPayload) _then;

/// Create a copy of BootstrapPayload
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? apiEndpoints = null,Object? subscriptionEndpoints = null,Object? nextBootstrapUrls = null,}) {
  return _then(_BootstrapPayload(
apiEndpoints: null == apiEndpoints ? _self._apiEndpoints : apiEndpoints // ignore: cast_nullable_to_non_nullable
as List<BootstrapEndpoint>,subscriptionEndpoints: null == subscriptionEndpoints ? _self._subscriptionEndpoints : subscriptionEndpoints // ignore: cast_nullable_to_non_nullable
as List<BootstrapEndpoint>,nextBootstrapUrls: null == nextBootstrapUrls ? _self._nextBootstrapUrls : nextBootstrapUrls // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

// dart format on
