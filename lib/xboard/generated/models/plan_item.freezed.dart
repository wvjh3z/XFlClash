// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../models/plan_item.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$PricePlan {

 XbPlanPeriod get period; double get amountYuan;
/// Create a copy of PricePlan
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PricePlanCopyWith<PricePlan> get copyWith => _$PricePlanCopyWithImpl<PricePlan>(this as PricePlan, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PricePlan&&(identical(other.period, period) || other.period == period)&&(identical(other.amountYuan, amountYuan) || other.amountYuan == amountYuan));
}


@override
int get hashCode => Object.hash(runtimeType,period,amountYuan);

@override
String toString() {
  return 'PricePlan(period: $period, amountYuan: $amountYuan)';
}


}

/// @nodoc
abstract mixin class $PricePlanCopyWith<$Res>  {
  factory $PricePlanCopyWith(PricePlan value, $Res Function(PricePlan) _then) = _$PricePlanCopyWithImpl;
@useResult
$Res call({
 XbPlanPeriod period, double amountYuan
});




}
/// @nodoc
class _$PricePlanCopyWithImpl<$Res>
    implements $PricePlanCopyWith<$Res> {
  _$PricePlanCopyWithImpl(this._self, this._then);

  final PricePlan _self;
  final $Res Function(PricePlan) _then;

/// Create a copy of PricePlan
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? period = null,Object? amountYuan = null,}) {
  return _then(_self.copyWith(
period: null == period ? _self.period : period // ignore: cast_nullable_to_non_nullable
as XbPlanPeriod,amountYuan: null == amountYuan ? _self.amountYuan : amountYuan // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [PricePlan].
extension PricePlanPatterns on PricePlan {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PricePlan value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PricePlan() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PricePlan value)  $default,){
final _that = this;
switch (_that) {
case _PricePlan():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PricePlan value)?  $default,){
final _that = this;
switch (_that) {
case _PricePlan() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( XbPlanPeriod period,  double amountYuan)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PricePlan() when $default != null:
return $default(_that.period,_that.amountYuan);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( XbPlanPeriod period,  double amountYuan)  $default,) {final _that = this;
switch (_that) {
case _PricePlan():
return $default(_that.period,_that.amountYuan);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( XbPlanPeriod period,  double amountYuan)?  $default,) {final _that = this;
switch (_that) {
case _PricePlan() when $default != null:
return $default(_that.period,_that.amountYuan);case _:
  return null;

}
}

}

/// @nodoc


class _PricePlan implements PricePlan {
  const _PricePlan({required this.period, required this.amountYuan});
  

@override final  XbPlanPeriod period;
@override final  double amountYuan;

/// Create a copy of PricePlan
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PricePlanCopyWith<_PricePlan> get copyWith => __$PricePlanCopyWithImpl<_PricePlan>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PricePlan&&(identical(other.period, period) || other.period == period)&&(identical(other.amountYuan, amountYuan) || other.amountYuan == amountYuan));
}


@override
int get hashCode => Object.hash(runtimeType,period,amountYuan);

@override
String toString() {
  return 'PricePlan(period: $period, amountYuan: $amountYuan)';
}


}

/// @nodoc
abstract mixin class _$PricePlanCopyWith<$Res> implements $PricePlanCopyWith<$Res> {
  factory _$PricePlanCopyWith(_PricePlan value, $Res Function(_PricePlan) _then) = __$PricePlanCopyWithImpl;
@override @useResult
$Res call({
 XbPlanPeriod period, double amountYuan
});




}
/// @nodoc
class __$PricePlanCopyWithImpl<$Res>
    implements _$PricePlanCopyWith<$Res> {
  __$PricePlanCopyWithImpl(this._self, this._then);

  final _PricePlan _self;
  final $Res Function(_PricePlan) _then;

/// Create a copy of PricePlan
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? period = null,Object? amountYuan = null,}) {
  return _then(_PricePlan(
period: null == period ? _self.period : period // ignore: cast_nullable_to_non_nullable
as XbPlanPeriod,amountYuan: null == amountYuan ? _self.amountYuan : amountYuan // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc
mixin _$PlanItem {

 int get id; String get name; String? get description;// 🔴 第12轮：PlanModel.transferEnable 是 double 单位 GB（≠ SubscriptionModel bytes）。
// 映射 transferEnableGb = plan.transferEnable.toInt()，UI 展示用 GB，勿与字节混算。
 int get transferEnableGb; List<PricePlan> get prices;
/// Create a copy of PlanItem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlanItemCopyWith<PlanItem> get copyWith => _$PlanItemCopyWithImpl<PlanItem>(this as PlanItem, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PlanItem&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.transferEnableGb, transferEnableGb) || other.transferEnableGb == transferEnableGb)&&const DeepCollectionEquality().equals(other.prices, prices));
}


@override
int get hashCode => Object.hash(runtimeType,id,name,description,transferEnableGb,const DeepCollectionEquality().hash(prices));

@override
String toString() {
  return 'PlanItem(id: $id, name: $name, description: $description, transferEnableGb: $transferEnableGb, prices: $prices)';
}


}

/// @nodoc
abstract mixin class $PlanItemCopyWith<$Res>  {
  factory $PlanItemCopyWith(PlanItem value, $Res Function(PlanItem) _then) = _$PlanItemCopyWithImpl;
@useResult
$Res call({
 int id, String name, String? description, int transferEnableGb, List<PricePlan> prices
});




}
/// @nodoc
class _$PlanItemCopyWithImpl<$Res>
    implements $PlanItemCopyWith<$Res> {
  _$PlanItemCopyWithImpl(this._self, this._then);

  final PlanItem _self;
  final $Res Function(PlanItem) _then;

/// Create a copy of PlanItem
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? description = freezed,Object? transferEnableGb = null,Object? prices = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,transferEnableGb: null == transferEnableGb ? _self.transferEnableGb : transferEnableGb // ignore: cast_nullable_to_non_nullable
as int,prices: null == prices ? _self.prices : prices // ignore: cast_nullable_to_non_nullable
as List<PricePlan>,
  ));
}

}


/// Adds pattern-matching-related methods to [PlanItem].
extension PlanItemPatterns on PlanItem {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PlanItem value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PlanItem() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PlanItem value)  $default,){
final _that = this;
switch (_that) {
case _PlanItem():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PlanItem value)?  $default,){
final _that = this;
switch (_that) {
case _PlanItem() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int id,  String name,  String? description,  int transferEnableGb,  List<PricePlan> prices)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PlanItem() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.transferEnableGb,_that.prices);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int id,  String name,  String? description,  int transferEnableGb,  List<PricePlan> prices)  $default,) {final _that = this;
switch (_that) {
case _PlanItem():
return $default(_that.id,_that.name,_that.description,_that.transferEnableGb,_that.prices);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int id,  String name,  String? description,  int transferEnableGb,  List<PricePlan> prices)?  $default,) {final _that = this;
switch (_that) {
case _PlanItem() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.transferEnableGb,_that.prices);case _:
  return null;

}
}

}

/// @nodoc


class _PlanItem implements PlanItem {
  const _PlanItem({required this.id, required this.name, this.description, required this.transferEnableGb, required final  List<PricePlan> prices}): _prices = prices;
  

@override final  int id;
@override final  String name;
@override final  String? description;
// 🔴 第12轮：PlanModel.transferEnable 是 double 单位 GB（≠ SubscriptionModel bytes）。
// 映射 transferEnableGb = plan.transferEnable.toInt()，UI 展示用 GB，勿与字节混算。
@override final  int transferEnableGb;
 final  List<PricePlan> _prices;
@override List<PricePlan> get prices {
  if (_prices is EqualUnmodifiableListView) return _prices;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_prices);
}


/// Create a copy of PlanItem
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PlanItemCopyWith<_PlanItem> get copyWith => __$PlanItemCopyWithImpl<_PlanItem>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PlanItem&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.transferEnableGb, transferEnableGb) || other.transferEnableGb == transferEnableGb)&&const DeepCollectionEquality().equals(other._prices, _prices));
}


@override
int get hashCode => Object.hash(runtimeType,id,name,description,transferEnableGb,const DeepCollectionEquality().hash(_prices));

@override
String toString() {
  return 'PlanItem(id: $id, name: $name, description: $description, transferEnableGb: $transferEnableGb, prices: $prices)';
}


}

/// @nodoc
abstract mixin class _$PlanItemCopyWith<$Res> implements $PlanItemCopyWith<$Res> {
  factory _$PlanItemCopyWith(_PlanItem value, $Res Function(_PlanItem) _then) = __$PlanItemCopyWithImpl;
@override @useResult
$Res call({
 int id, String name, String? description, int transferEnableGb, List<PricePlan> prices
});




}
/// @nodoc
class __$PlanItemCopyWithImpl<$Res>
    implements _$PlanItemCopyWith<$Res> {
  __$PlanItemCopyWithImpl(this._self, this._then);

  final _PlanItem _self;
  final $Res Function(_PlanItem) _then;

/// Create a copy of PlanItem
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? description = freezed,Object? transferEnableGb = null,Object? prices = null,}) {
  return _then(_PlanItem(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,transferEnableGb: null == transferEnableGb ? _self.transferEnableGb : transferEnableGb // ignore: cast_nullable_to_non_nullable
as int,prices: null == prices ? _self._prices : prices // ignore: cast_nullable_to_non_nullable
as List<PricePlan>,
  ));
}


}

// dart format on
