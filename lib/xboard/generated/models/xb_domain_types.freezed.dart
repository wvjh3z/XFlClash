// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../models/xb_domain_types.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$XbCheckLogin {

 bool get isLogin;
/// Create a copy of XbCheckLogin
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$XbCheckLoginCopyWith<XbCheckLogin> get copyWith => _$XbCheckLoginCopyWithImpl<XbCheckLogin>(this as XbCheckLogin, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is XbCheckLogin&&(identical(other.isLogin, isLogin) || other.isLogin == isLogin));
}


@override
int get hashCode => Object.hash(runtimeType,isLogin);

@override
String toString() {
  return 'XbCheckLogin(isLogin: $isLogin)';
}


}

/// @nodoc
abstract mixin class $XbCheckLoginCopyWith<$Res>  {
  factory $XbCheckLoginCopyWith(XbCheckLogin value, $Res Function(XbCheckLogin) _then) = _$XbCheckLoginCopyWithImpl;
@useResult
$Res call({
 bool isLogin
});




}
/// @nodoc
class _$XbCheckLoginCopyWithImpl<$Res>
    implements $XbCheckLoginCopyWith<$Res> {
  _$XbCheckLoginCopyWithImpl(this._self, this._then);

  final XbCheckLogin _self;
  final $Res Function(XbCheckLogin) _then;

/// Create a copy of XbCheckLogin
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? isLogin = null,}) {
  return _then(_self.copyWith(
isLogin: null == isLogin ? _self.isLogin : isLogin // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [XbCheckLogin].
extension XbCheckLoginPatterns on XbCheckLogin {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _XbCheckLogin value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _XbCheckLogin() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _XbCheckLogin value)  $default,){
final _that = this;
switch (_that) {
case _XbCheckLogin():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _XbCheckLogin value)?  $default,){
final _that = this;
switch (_that) {
case _XbCheckLogin() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool isLogin)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _XbCheckLogin() when $default != null:
return $default(_that.isLogin);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool isLogin)  $default,) {final _that = this;
switch (_that) {
case _XbCheckLogin():
return $default(_that.isLogin);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool isLogin)?  $default,) {final _that = this;
switch (_that) {
case _XbCheckLogin() when $default != null:
return $default(_that.isLogin);case _:
  return null;

}
}

}

/// @nodoc


class _XbCheckLogin implements XbCheckLogin {
  const _XbCheckLogin({required this.isLogin});
  

@override final  bool isLogin;

/// Create a copy of XbCheckLogin
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$XbCheckLoginCopyWith<_XbCheckLogin> get copyWith => __$XbCheckLoginCopyWithImpl<_XbCheckLogin>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _XbCheckLogin&&(identical(other.isLogin, isLogin) || other.isLogin == isLogin));
}


@override
int get hashCode => Object.hash(runtimeType,isLogin);

@override
String toString() {
  return 'XbCheckLogin(isLogin: $isLogin)';
}


}

/// @nodoc
abstract mixin class _$XbCheckLoginCopyWith<$Res> implements $XbCheckLoginCopyWith<$Res> {
  factory _$XbCheckLoginCopyWith(_XbCheckLogin value, $Res Function(_XbCheckLogin) _then) = __$XbCheckLoginCopyWithImpl;
@override @useResult
$Res call({
 bool isLogin
});




}
/// @nodoc
class __$XbCheckLoginCopyWithImpl<$Res>
    implements _$XbCheckLoginCopyWith<$Res> {
  __$XbCheckLoginCopyWithImpl(this._self, this._then);

  final _XbCheckLogin _self;
  final $Res Function(_XbCheckLogin) _then;

/// Create a copy of XbCheckLogin
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? isLogin = null,}) {
  return _then(_XbCheckLogin(
isLogin: null == isLogin ? _self.isLogin : isLogin // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$XbPagedList<T> {

 List<T> get items; int get page; int get pageSize; int get total;
/// Create a copy of XbPagedList
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$XbPagedListCopyWith<T, XbPagedList<T>> get copyWith => _$XbPagedListCopyWithImpl<T, XbPagedList<T>>(this as XbPagedList<T>, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is XbPagedList<T>&&const DeepCollectionEquality().equals(other.items, items)&&(identical(other.page, page) || other.page == page)&&(identical(other.pageSize, pageSize) || other.pageSize == pageSize)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(items),page,pageSize,total);

@override
String toString() {
  return 'XbPagedList<$T>(items: $items, page: $page, pageSize: $pageSize, total: $total)';
}


}

/// @nodoc
abstract mixin class $XbPagedListCopyWith<T,$Res>  {
  factory $XbPagedListCopyWith(XbPagedList<T> value, $Res Function(XbPagedList<T>) _then) = _$XbPagedListCopyWithImpl;
@useResult
$Res call({
 List<T> items, int page, int pageSize, int total
});




}
/// @nodoc
class _$XbPagedListCopyWithImpl<T,$Res>
    implements $XbPagedListCopyWith<T, $Res> {
  _$XbPagedListCopyWithImpl(this._self, this._then);

  final XbPagedList<T> _self;
  final $Res Function(XbPagedList<T>) _then;

/// Create a copy of XbPagedList
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? items = null,Object? page = null,Object? pageSize = null,Object? total = null,}) {
  return _then(_self.copyWith(
items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<T>,page: null == page ? _self.page : page // ignore: cast_nullable_to_non_nullable
as int,pageSize: null == pageSize ? _self.pageSize : pageSize // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [XbPagedList].
extension XbPagedListPatterns<T> on XbPagedList<T> {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _XbPagedList<T> value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _XbPagedList() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _XbPagedList<T> value)  $default,){
final _that = this;
switch (_that) {
case _XbPagedList():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _XbPagedList<T> value)?  $default,){
final _that = this;
switch (_that) {
case _XbPagedList() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<T> items,  int page,  int pageSize,  int total)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _XbPagedList() when $default != null:
return $default(_that.items,_that.page,_that.pageSize,_that.total);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<T> items,  int page,  int pageSize,  int total)  $default,) {final _that = this;
switch (_that) {
case _XbPagedList():
return $default(_that.items,_that.page,_that.pageSize,_that.total);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<T> items,  int page,  int pageSize,  int total)?  $default,) {final _that = this;
switch (_that) {
case _XbPagedList() when $default != null:
return $default(_that.items,_that.page,_that.pageSize,_that.total);case _:
  return null;

}
}

}

/// @nodoc


class _XbPagedList<T> implements XbPagedList<T> {
  const _XbPagedList({required final  List<T> items, required this.page, required this.pageSize, required this.total}): _items = items;
  

 final  List<T> _items;
@override List<T> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}

@override final  int page;
@override final  int pageSize;
@override final  int total;

/// Create a copy of XbPagedList
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$XbPagedListCopyWith<T, _XbPagedList<T>> get copyWith => __$XbPagedListCopyWithImpl<T, _XbPagedList<T>>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _XbPagedList<T>&&const DeepCollectionEquality().equals(other._items, _items)&&(identical(other.page, page) || other.page == page)&&(identical(other.pageSize, pageSize) || other.pageSize == pageSize)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_items),page,pageSize,total);

@override
String toString() {
  return 'XbPagedList<$T>(items: $items, page: $page, pageSize: $pageSize, total: $total)';
}


}

/// @nodoc
abstract mixin class _$XbPagedListCopyWith<T,$Res> implements $XbPagedListCopyWith<T, $Res> {
  factory _$XbPagedListCopyWith(_XbPagedList<T> value, $Res Function(_XbPagedList<T>) _then) = __$XbPagedListCopyWithImpl;
@override @useResult
$Res call({
 List<T> items, int page, int pageSize, int total
});




}
/// @nodoc
class __$XbPagedListCopyWithImpl<T,$Res>
    implements _$XbPagedListCopyWith<T, $Res> {
  __$XbPagedListCopyWithImpl(this._self, this._then);

  final _XbPagedList<T> _self;
  final $Res Function(_XbPagedList<T>) _then;

/// Create a copy of XbPagedList
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? items = null,Object? page = null,Object? pageSize = null,Object? total = null,}) {
  return _then(_XbPagedList<T>(
items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<T>,page: null == page ? _self.page : page // ignore: cast_nullable_to_non_nullable
as int,pageSize: null == pageSize ? _self.pageSize : pageSize // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
mixin _$PaymentMethodItem {

 String get id; String get name; String? get icon; double? get feeFixedYuan; double? get feePercent;
/// Create a copy of PaymentMethodItem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PaymentMethodItemCopyWith<PaymentMethodItem> get copyWith => _$PaymentMethodItemCopyWithImpl<PaymentMethodItem>(this as PaymentMethodItem, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PaymentMethodItem&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.icon, icon) || other.icon == icon)&&(identical(other.feeFixedYuan, feeFixedYuan) || other.feeFixedYuan == feeFixedYuan)&&(identical(other.feePercent, feePercent) || other.feePercent == feePercent));
}


@override
int get hashCode => Object.hash(runtimeType,id,name,icon,feeFixedYuan,feePercent);

@override
String toString() {
  return 'PaymentMethodItem(id: $id, name: $name, icon: $icon, feeFixedYuan: $feeFixedYuan, feePercent: $feePercent)';
}


}

/// @nodoc
abstract mixin class $PaymentMethodItemCopyWith<$Res>  {
  factory $PaymentMethodItemCopyWith(PaymentMethodItem value, $Res Function(PaymentMethodItem) _then) = _$PaymentMethodItemCopyWithImpl;
@useResult
$Res call({
 String id, String name, String? icon, double? feeFixedYuan, double? feePercent
});




}
/// @nodoc
class _$PaymentMethodItemCopyWithImpl<$Res>
    implements $PaymentMethodItemCopyWith<$Res> {
  _$PaymentMethodItemCopyWithImpl(this._self, this._then);

  final PaymentMethodItem _self;
  final $Res Function(PaymentMethodItem) _then;

/// Create a copy of PaymentMethodItem
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? icon = freezed,Object? feeFixedYuan = freezed,Object? feePercent = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,icon: freezed == icon ? _self.icon : icon // ignore: cast_nullable_to_non_nullable
as String?,feeFixedYuan: freezed == feeFixedYuan ? _self.feeFixedYuan : feeFixedYuan // ignore: cast_nullable_to_non_nullable
as double?,feePercent: freezed == feePercent ? _self.feePercent : feePercent // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}

}


/// Adds pattern-matching-related methods to [PaymentMethodItem].
extension PaymentMethodItemPatterns on PaymentMethodItem {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PaymentMethodItem value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PaymentMethodItem() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PaymentMethodItem value)  $default,){
final _that = this;
switch (_that) {
case _PaymentMethodItem():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PaymentMethodItem value)?  $default,){
final _that = this;
switch (_that) {
case _PaymentMethodItem() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String? icon,  double? feeFixedYuan,  double? feePercent)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PaymentMethodItem() when $default != null:
return $default(_that.id,_that.name,_that.icon,_that.feeFixedYuan,_that.feePercent);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String? icon,  double? feeFixedYuan,  double? feePercent)  $default,) {final _that = this;
switch (_that) {
case _PaymentMethodItem():
return $default(_that.id,_that.name,_that.icon,_that.feeFixedYuan,_that.feePercent);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String? icon,  double? feeFixedYuan,  double? feePercent)?  $default,) {final _that = this;
switch (_that) {
case _PaymentMethodItem() when $default != null:
return $default(_that.id,_that.name,_that.icon,_that.feeFixedYuan,_that.feePercent);case _:
  return null;

}
}

}

/// @nodoc


class _PaymentMethodItem implements PaymentMethodItem {
  const _PaymentMethodItem({required this.id, required this.name, this.icon, this.feeFixedYuan, this.feePercent});
  

@override final  String id;
@override final  String name;
@override final  String? icon;
@override final  double? feeFixedYuan;
@override final  double? feePercent;

/// Create a copy of PaymentMethodItem
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PaymentMethodItemCopyWith<_PaymentMethodItem> get copyWith => __$PaymentMethodItemCopyWithImpl<_PaymentMethodItem>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PaymentMethodItem&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.icon, icon) || other.icon == icon)&&(identical(other.feeFixedYuan, feeFixedYuan) || other.feeFixedYuan == feeFixedYuan)&&(identical(other.feePercent, feePercent) || other.feePercent == feePercent));
}


@override
int get hashCode => Object.hash(runtimeType,id,name,icon,feeFixedYuan,feePercent);

@override
String toString() {
  return 'PaymentMethodItem(id: $id, name: $name, icon: $icon, feeFixedYuan: $feeFixedYuan, feePercent: $feePercent)';
}


}

/// @nodoc
abstract mixin class _$PaymentMethodItemCopyWith<$Res> implements $PaymentMethodItemCopyWith<$Res> {
  factory _$PaymentMethodItemCopyWith(_PaymentMethodItem value, $Res Function(_PaymentMethodItem) _then) = __$PaymentMethodItemCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String? icon, double? feeFixedYuan, double? feePercent
});




}
/// @nodoc
class __$PaymentMethodItemCopyWithImpl<$Res>
    implements _$PaymentMethodItemCopyWith<$Res> {
  __$PaymentMethodItemCopyWithImpl(this._self, this._then);

  final _PaymentMethodItem _self;
  final $Res Function(_PaymentMethodItem) _then;

/// Create a copy of PaymentMethodItem
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? icon = freezed,Object? feeFixedYuan = freezed,Object? feePercent = freezed,}) {
  return _then(_PaymentMethodItem(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,icon: freezed == icon ? _self.icon : icon // ignore: cast_nullable_to_non_nullable
as String?,feeFixedYuan: freezed == feeFixedYuan ? _self.feeFixedYuan : feeFixedYuan // ignore: cast_nullable_to_non_nullable
as double?,feePercent: freezed == feePercent ? _self.feePercent : feePercent // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

/// @nodoc
mixin _$IpMirrorConfigUi {

 bool get enabled; List<String> get urls; Duration get throttle; Duration get fetchTimeout;
/// Create a copy of IpMirrorConfigUi
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IpMirrorConfigUiCopyWith<IpMirrorConfigUi> get copyWith => _$IpMirrorConfigUiCopyWithImpl<IpMirrorConfigUi>(this as IpMirrorConfigUi, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IpMirrorConfigUi&&(identical(other.enabled, enabled) || other.enabled == enabled)&&const DeepCollectionEquality().equals(other.urls, urls)&&(identical(other.throttle, throttle) || other.throttle == throttle)&&(identical(other.fetchTimeout, fetchTimeout) || other.fetchTimeout == fetchTimeout));
}


@override
int get hashCode => Object.hash(runtimeType,enabled,const DeepCollectionEquality().hash(urls),throttle,fetchTimeout);

@override
String toString() {
  return 'IpMirrorConfigUi(enabled: $enabled, urls: $urls, throttle: $throttle, fetchTimeout: $fetchTimeout)';
}


}

/// @nodoc
abstract mixin class $IpMirrorConfigUiCopyWith<$Res>  {
  factory $IpMirrorConfigUiCopyWith(IpMirrorConfigUi value, $Res Function(IpMirrorConfigUi) _then) = _$IpMirrorConfigUiCopyWithImpl;
@useResult
$Res call({
 bool enabled, List<String> urls, Duration throttle, Duration fetchTimeout
});




}
/// @nodoc
class _$IpMirrorConfigUiCopyWithImpl<$Res>
    implements $IpMirrorConfigUiCopyWith<$Res> {
  _$IpMirrorConfigUiCopyWithImpl(this._self, this._then);

  final IpMirrorConfigUi _self;
  final $Res Function(IpMirrorConfigUi) _then;

/// Create a copy of IpMirrorConfigUi
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? enabled = null,Object? urls = null,Object? throttle = null,Object? fetchTimeout = null,}) {
  return _then(_self.copyWith(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,urls: null == urls ? _self.urls : urls // ignore: cast_nullable_to_non_nullable
as List<String>,throttle: null == throttle ? _self.throttle : throttle // ignore: cast_nullable_to_non_nullable
as Duration,fetchTimeout: null == fetchTimeout ? _self.fetchTimeout : fetchTimeout // ignore: cast_nullable_to_non_nullable
as Duration,
  ));
}

}


/// Adds pattern-matching-related methods to [IpMirrorConfigUi].
extension IpMirrorConfigUiPatterns on IpMirrorConfigUi {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _IpMirrorConfigUi value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _IpMirrorConfigUi() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _IpMirrorConfigUi value)  $default,){
final _that = this;
switch (_that) {
case _IpMirrorConfigUi():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _IpMirrorConfigUi value)?  $default,){
final _that = this;
switch (_that) {
case _IpMirrorConfigUi() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool enabled,  List<String> urls,  Duration throttle,  Duration fetchTimeout)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _IpMirrorConfigUi() when $default != null:
return $default(_that.enabled,_that.urls,_that.throttle,_that.fetchTimeout);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool enabled,  List<String> urls,  Duration throttle,  Duration fetchTimeout)  $default,) {final _that = this;
switch (_that) {
case _IpMirrorConfigUi():
return $default(_that.enabled,_that.urls,_that.throttle,_that.fetchTimeout);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool enabled,  List<String> urls,  Duration throttle,  Duration fetchTimeout)?  $default,) {final _that = this;
switch (_that) {
case _IpMirrorConfigUi() when $default != null:
return $default(_that.enabled,_that.urls,_that.throttle,_that.fetchTimeout);case _:
  return null;

}
}

}

/// @nodoc


class _IpMirrorConfigUi implements IpMirrorConfigUi {
  const _IpMirrorConfigUi({required this.enabled, required final  List<String> urls, required this.throttle, required this.fetchTimeout}): _urls = urls;
  

@override final  bool enabled;
 final  List<String> _urls;
@override List<String> get urls {
  if (_urls is EqualUnmodifiableListView) return _urls;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_urls);
}

@override final  Duration throttle;
@override final  Duration fetchTimeout;

/// Create a copy of IpMirrorConfigUi
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$IpMirrorConfigUiCopyWith<_IpMirrorConfigUi> get copyWith => __$IpMirrorConfigUiCopyWithImpl<_IpMirrorConfigUi>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _IpMirrorConfigUi&&(identical(other.enabled, enabled) || other.enabled == enabled)&&const DeepCollectionEquality().equals(other._urls, _urls)&&(identical(other.throttle, throttle) || other.throttle == throttle)&&(identical(other.fetchTimeout, fetchTimeout) || other.fetchTimeout == fetchTimeout));
}


@override
int get hashCode => Object.hash(runtimeType,enabled,const DeepCollectionEquality().hash(_urls),throttle,fetchTimeout);

@override
String toString() {
  return 'IpMirrorConfigUi(enabled: $enabled, urls: $urls, throttle: $throttle, fetchTimeout: $fetchTimeout)';
}


}

/// @nodoc
abstract mixin class _$IpMirrorConfigUiCopyWith<$Res> implements $IpMirrorConfigUiCopyWith<$Res> {
  factory _$IpMirrorConfigUiCopyWith(_IpMirrorConfigUi value, $Res Function(_IpMirrorConfigUi) _then) = __$IpMirrorConfigUiCopyWithImpl;
@override @useResult
$Res call({
 bool enabled, List<String> urls, Duration throttle, Duration fetchTimeout
});




}
/// @nodoc
class __$IpMirrorConfigUiCopyWithImpl<$Res>
    implements _$IpMirrorConfigUiCopyWith<$Res> {
  __$IpMirrorConfigUiCopyWithImpl(this._self, this._then);

  final _IpMirrorConfigUi _self;
  final $Res Function(_IpMirrorConfigUi) _then;

/// Create a copy of IpMirrorConfigUi
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? enabled = null,Object? urls = null,Object? throttle = null,Object? fetchTimeout = null,}) {
  return _then(_IpMirrorConfigUi(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,urls: null == urls ? _self._urls : urls // ignore: cast_nullable_to_non_nullable
as List<String>,throttle: null == throttle ? _self.throttle : throttle // ignore: cast_nullable_to_non_nullable
as Duration,fetchTimeout: null == fetchTimeout ? _self.fetchTimeout : fetchTimeout // ignore: cast_nullable_to_non_nullable
as Duration,
  ));
}


}

/// @nodoc
mixin _$CouponInfo {

 String get code; int get type;// 1=金额折扣(cents) / 2=百分比(0-100)
 int get value; int? get discountAmountCents;// 来自下单后 OrderModel.discountAmount（非 CouponModel）
 DateTime? get endedAt;
/// Create a copy of CouponInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CouponInfoCopyWith<CouponInfo> get copyWith => _$CouponInfoCopyWithImpl<CouponInfo>(this as CouponInfo, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CouponInfo&&(identical(other.code, code) || other.code == code)&&(identical(other.type, type) || other.type == type)&&(identical(other.value, value) || other.value == value)&&(identical(other.discountAmountCents, discountAmountCents) || other.discountAmountCents == discountAmountCents)&&(identical(other.endedAt, endedAt) || other.endedAt == endedAt));
}


@override
int get hashCode => Object.hash(runtimeType,code,type,value,discountAmountCents,endedAt);

@override
String toString() {
  return 'CouponInfo(code: $code, type: $type, value: $value, discountAmountCents: $discountAmountCents, endedAt: $endedAt)';
}


}

/// @nodoc
abstract mixin class $CouponInfoCopyWith<$Res>  {
  factory $CouponInfoCopyWith(CouponInfo value, $Res Function(CouponInfo) _then) = _$CouponInfoCopyWithImpl;
@useResult
$Res call({
 String code, int type, int value, int? discountAmountCents, DateTime? endedAt
});




}
/// @nodoc
class _$CouponInfoCopyWithImpl<$Res>
    implements $CouponInfoCopyWith<$Res> {
  _$CouponInfoCopyWithImpl(this._self, this._then);

  final CouponInfo _self;
  final $Res Function(CouponInfo) _then;

/// Create a copy of CouponInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? code = null,Object? type = null,Object? value = null,Object? discountAmountCents = freezed,Object? endedAt = freezed,}) {
  return _then(_self.copyWith(
code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as int,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as int,discountAmountCents: freezed == discountAmountCents ? _self.discountAmountCents : discountAmountCents // ignore: cast_nullable_to_non_nullable
as int?,endedAt: freezed == endedAt ? _self.endedAt : endedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [CouponInfo].
extension CouponInfoPatterns on CouponInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CouponInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CouponInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CouponInfo value)  $default,){
final _that = this;
switch (_that) {
case _CouponInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CouponInfo value)?  $default,){
final _that = this;
switch (_that) {
case _CouponInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String code,  int type,  int value,  int? discountAmountCents,  DateTime? endedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CouponInfo() when $default != null:
return $default(_that.code,_that.type,_that.value,_that.discountAmountCents,_that.endedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String code,  int type,  int value,  int? discountAmountCents,  DateTime? endedAt)  $default,) {final _that = this;
switch (_that) {
case _CouponInfo():
return $default(_that.code,_that.type,_that.value,_that.discountAmountCents,_that.endedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String code,  int type,  int value,  int? discountAmountCents,  DateTime? endedAt)?  $default,) {final _that = this;
switch (_that) {
case _CouponInfo() when $default != null:
return $default(_that.code,_that.type,_that.value,_that.discountAmountCents,_that.endedAt);case _:
  return null;

}
}

}

/// @nodoc


class _CouponInfo implements CouponInfo {
  const _CouponInfo({required this.code, required this.type, required this.value, this.discountAmountCents, this.endedAt});
  

@override final  String code;
@override final  int type;
// 1=金额折扣(cents) / 2=百分比(0-100)
@override final  int value;
@override final  int? discountAmountCents;
// 来自下单后 OrderModel.discountAmount（非 CouponModel）
@override final  DateTime? endedAt;

/// Create a copy of CouponInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CouponInfoCopyWith<_CouponInfo> get copyWith => __$CouponInfoCopyWithImpl<_CouponInfo>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CouponInfo&&(identical(other.code, code) || other.code == code)&&(identical(other.type, type) || other.type == type)&&(identical(other.value, value) || other.value == value)&&(identical(other.discountAmountCents, discountAmountCents) || other.discountAmountCents == discountAmountCents)&&(identical(other.endedAt, endedAt) || other.endedAt == endedAt));
}


@override
int get hashCode => Object.hash(runtimeType,code,type,value,discountAmountCents,endedAt);

@override
String toString() {
  return 'CouponInfo(code: $code, type: $type, value: $value, discountAmountCents: $discountAmountCents, endedAt: $endedAt)';
}


}

/// @nodoc
abstract mixin class _$CouponInfoCopyWith<$Res> implements $CouponInfoCopyWith<$Res> {
  factory _$CouponInfoCopyWith(_CouponInfo value, $Res Function(_CouponInfo) _then) = __$CouponInfoCopyWithImpl;
@override @useResult
$Res call({
 String code, int type, int value, int? discountAmountCents, DateTime? endedAt
});




}
/// @nodoc
class __$CouponInfoCopyWithImpl<$Res>
    implements _$CouponInfoCopyWith<$Res> {
  __$CouponInfoCopyWithImpl(this._self, this._then);

  final _CouponInfo _self;
  final $Res Function(_CouponInfo) _then;

/// Create a copy of CouponInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? code = null,Object? type = null,Object? value = null,Object? discountAmountCents = freezed,Object? endedAt = freezed,}) {
  return _then(_CouponInfo(
code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as int,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as int,discountAmountCents: freezed == discountAmountCents ? _self.discountAmountCents : discountAmountCents // ignore: cast_nullable_to_non_nullable
as int?,endedAt: freezed == endedAt ? _self.endedAt : endedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
