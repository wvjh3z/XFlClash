// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../models/order_summary.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$OrderSummary {

 String get tradeNo; String? get planName; XbPlanPeriod get period; double get totalAmountYuan; XbOrderStatus get status; DateTime get createdAt;
/// Create a copy of OrderSummary
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OrderSummaryCopyWith<OrderSummary> get copyWith => _$OrderSummaryCopyWithImpl<OrderSummary>(this as OrderSummary, _$identity);

  /// Serializes this OrderSummary to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as OrderSummary;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OrderSummary&&(identical(other.tradeNo, _this.tradeNo) || other.tradeNo == _this.tradeNo)&&(identical(other.planName, _this.planName) || other.planName == _this.planName)&&(identical(other.period, _this.period) || other.period == _this.period)&&(identical(other.totalAmountYuan, _this.totalAmountYuan) || other.totalAmountYuan == _this.totalAmountYuan)&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.createdAt, _this.createdAt) || other.createdAt == _this.createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as OrderSummary;
  return Object.hash(runtimeType,_this.tradeNo,_this.planName,_this.period,_this.totalAmountYuan,_this.status,_this.createdAt);
}

@override
String toString() {
  final _this = this as OrderSummary;
  return 'OrderSummary(tradeNo: ${_this.tradeNo}, planName: ${_this.planName}, period: ${_this.period}, totalAmountYuan: ${_this.totalAmountYuan}, status: ${_this.status}, createdAt: ${_this.createdAt})';
}


}

/// @nodoc
abstract mixin class $OrderSummaryCopyWith<$Res>  {
  factory $OrderSummaryCopyWith(OrderSummary value, $Res Function(OrderSummary) _then) = _$OrderSummaryCopyWithImpl;
@useResult
$Res call({
 String tradeNo, String? planName, XbPlanPeriod period, double totalAmountYuan, XbOrderStatus status, DateTime createdAt
});




}
/// @nodoc
class _$OrderSummaryCopyWithImpl<$Res>
    implements $OrderSummaryCopyWith<$Res> {
  _$OrderSummaryCopyWithImpl(this._self, this._then);

  final OrderSummary _self;
  final $Res Function(OrderSummary) _then;

/// Create a copy of OrderSummary
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tradeNo = null,Object? planName = freezed,Object? period = null,Object? totalAmountYuan = null,Object? status = null,Object? createdAt = null,}) {
  return _then(OrderSummary(
tradeNo: null == tradeNo ? _self.tradeNo : tradeNo // ignore: cast_nullable_to_non_nullable
as String,planName: freezed == planName ? _self.planName : planName // ignore: cast_nullable_to_non_nullable
as String?,period: null == period ? _self.period : period // ignore: cast_nullable_to_non_nullable
as XbPlanPeriod,totalAmountYuan: null == totalAmountYuan ? _self.totalAmountYuan : totalAmountYuan // ignore: cast_nullable_to_non_nullable
as double,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as XbOrderStatus,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [OrderSummary].
extension OrderSummaryPatterns on OrderSummary {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _OrderSummary value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _OrderSummary() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _OrderSummary value)  $default,){
final _that = this;
switch (_that) {
case _OrderSummary():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _OrderSummary value)?  $default,){
final _that = this;
switch (_that) {
case _OrderSummary() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String tradeNo,  String? planName,  XbPlanPeriod period,  double totalAmountYuan,  XbOrderStatus status,  DateTime createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _OrderSummary() when $default != null:
return $default(_that.tradeNo,_that.planName,_that.period,_that.totalAmountYuan,_that.status,_that.createdAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String tradeNo,  String? planName,  XbPlanPeriod period,  double totalAmountYuan,  XbOrderStatus status,  DateTime createdAt)  $default,) {final _that = this;
switch (_that) {
case _OrderSummary():
return $default(_that.tradeNo,_that.planName,_that.period,_that.totalAmountYuan,_that.status,_that.createdAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String tradeNo,  String? planName,  XbPlanPeriod period,  double totalAmountYuan,  XbOrderStatus status,  DateTime createdAt)?  $default,) {final _that = this;
switch (_that) {
case _OrderSummary() when $default != null:
return $default(_that.tradeNo,_that.planName,_that.period,_that.totalAmountYuan,_that.status,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _OrderSummary implements OrderSummary {
  const _OrderSummary({required this.tradeNo, this.planName, required this.period, required this.totalAmountYuan, required this.status, required this.createdAt});
  factory _OrderSummary.fromJson(Map<String, dynamic> json) => _$OrderSummaryFromJson(json);

@override final  String tradeNo;
@override final  String? planName;
@override final  XbPlanPeriod period;
@override final  double totalAmountYuan;
@override final  XbOrderStatus status;
@override final  DateTime createdAt;

/// Create a copy of OrderSummary
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$OrderSummaryCopyWith<_OrderSummary> get copyWith => __$OrderSummaryCopyWithImpl<_OrderSummary>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$OrderSummaryToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _OrderSummary&&(identical(other.tradeNo, tradeNo) || other.tradeNo == tradeNo)&&(identical(other.planName, planName) || other.planName == planName)&&(identical(other.period, period) || other.period == period)&&(identical(other.totalAmountYuan, totalAmountYuan) || other.totalAmountYuan == totalAmountYuan)&&(identical(other.status, status) || other.status == status)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,tradeNo,planName,period,totalAmountYuan,status,createdAt);
}

@override
String toString() {
    return 'OrderSummary(tradeNo: $tradeNo, planName: $planName, period: $period, totalAmountYuan: $totalAmountYuan, status: $status, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$OrderSummaryCopyWith<$Res> implements $OrderSummaryCopyWith<$Res> {
  factory _$OrderSummaryCopyWith(_OrderSummary value, $Res Function(_OrderSummary) _then) = __$OrderSummaryCopyWithImpl;
@override @useResult
$Res call({
 String tradeNo, String? planName, XbPlanPeriod period, double totalAmountYuan, XbOrderStatus status, DateTime createdAt
});




}
/// @nodoc
class __$OrderSummaryCopyWithImpl<$Res>
    implements _$OrderSummaryCopyWith<$Res> {
  __$OrderSummaryCopyWithImpl(this._self, this._then);

  final _OrderSummary _self;
  final $Res Function(_OrderSummary) _then;

/// Create a copy of OrderSummary
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tradeNo = null,Object? planName = freezed,Object? period = null,Object? totalAmountYuan = null,Object? status = null,Object? createdAt = null,}) {
  return _then(_OrderSummary(
tradeNo: null == tradeNo ? _self.tradeNo : tradeNo // ignore: cast_nullable_to_non_nullable
as String,planName: freezed == planName ? _self.planName : planName // ignore: cast_nullable_to_non_nullable
as String?,period: null == period ? _self.period : period // ignore: cast_nullable_to_non_nullable
as XbPlanPeriod,totalAmountYuan: null == totalAmountYuan ? _self.totalAmountYuan : totalAmountYuan // ignore: cast_nullable_to_non_nullable
as double,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as XbOrderStatus,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}

/// @nodoc
mixin _$OrderDetail {

 OrderSummary get summary; PaymentMethodItem? get paymentMethod; double? get balanceAmountYuan; double? get surplusAmountYuan; double? get discountAmountYuan; double? get handlingAmountYuan;
/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OrderDetailCopyWith<OrderDetail> get copyWith => _$OrderDetailCopyWithImpl<OrderDetail>(this as OrderDetail, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as OrderDetail;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OrderDetail&&(identical(other.summary, _this.summary) || other.summary == _this.summary)&&(identical(other.paymentMethod, _this.paymentMethod) || other.paymentMethod == _this.paymentMethod)&&(identical(other.balanceAmountYuan, _this.balanceAmountYuan) || other.balanceAmountYuan == _this.balanceAmountYuan)&&(identical(other.surplusAmountYuan, _this.surplusAmountYuan) || other.surplusAmountYuan == _this.surplusAmountYuan)&&(identical(other.discountAmountYuan, _this.discountAmountYuan) || other.discountAmountYuan == _this.discountAmountYuan)&&(identical(other.handlingAmountYuan, _this.handlingAmountYuan) || other.handlingAmountYuan == _this.handlingAmountYuan));
}


@override
int get hashCode {
  final _this = this as OrderDetail;
  return Object.hash(runtimeType,_this.summary,_this.paymentMethod,_this.balanceAmountYuan,_this.surplusAmountYuan,_this.discountAmountYuan,_this.handlingAmountYuan);
}

@override
String toString() {
  final _this = this as OrderDetail;
  return 'OrderDetail(summary: ${_this.summary}, paymentMethod: ${_this.paymentMethod}, balanceAmountYuan: ${_this.balanceAmountYuan}, surplusAmountYuan: ${_this.surplusAmountYuan}, discountAmountYuan: ${_this.discountAmountYuan}, handlingAmountYuan: ${_this.handlingAmountYuan})';
}


}

/// @nodoc
abstract mixin class $OrderDetailCopyWith<$Res>  {
  factory $OrderDetailCopyWith(OrderDetail value, $Res Function(OrderDetail) _then) = _$OrderDetailCopyWithImpl;
@useResult
$Res call({
 OrderSummary summary, PaymentMethodItem? paymentMethod, double? balanceAmountYuan, double? surplusAmountYuan, double? discountAmountYuan, double? handlingAmountYuan
});


$OrderSummaryCopyWith<$Res> get summary;$PaymentMethodItemCopyWith<$Res>? get paymentMethod;

}
/// @nodoc
class _$OrderDetailCopyWithImpl<$Res>
    implements $OrderDetailCopyWith<$Res> {
  _$OrderDetailCopyWithImpl(this._self, this._then);

  final OrderDetail _self;
  final $Res Function(OrderDetail) _then;

/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? summary = null,Object? paymentMethod = freezed,Object? balanceAmountYuan = freezed,Object? surplusAmountYuan = freezed,Object? discountAmountYuan = freezed,Object? handlingAmountYuan = freezed,}) {
  return _then(OrderDetail(
summary: null == summary ? _self.summary : summary // ignore: cast_nullable_to_non_nullable
as OrderSummary,paymentMethod: freezed == paymentMethod ? _self.paymentMethod : paymentMethod // ignore: cast_nullable_to_non_nullable
as PaymentMethodItem?,balanceAmountYuan: freezed == balanceAmountYuan ? _self.balanceAmountYuan : balanceAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,surplusAmountYuan: freezed == surplusAmountYuan ? _self.surplusAmountYuan : surplusAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,discountAmountYuan: freezed == discountAmountYuan ? _self.discountAmountYuan : discountAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,handlingAmountYuan: freezed == handlingAmountYuan ? _self.handlingAmountYuan : handlingAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}
/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$OrderSummaryCopyWith<$Res> get summary {
  
  return $OrderSummaryCopyWith<$Res>(_self.summary, (value) {
    return _then(_self.copyWith(summary: value));
  });
}/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PaymentMethodItemCopyWith<$Res>? get paymentMethod {
    if (_self.paymentMethod == null) {
    return null;
  }

  return $PaymentMethodItemCopyWith<$Res>(_self.paymentMethod!, (value) {
    return _then(_self.copyWith(paymentMethod: value));
  });
}
}


/// Adds pattern-matching-related methods to [OrderDetail].
extension OrderDetailPatterns on OrderDetail {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _OrderDetail value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _OrderDetail() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _OrderDetail value)  $default,){
final _that = this;
switch (_that) {
case _OrderDetail():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _OrderDetail value)?  $default,){
final _that = this;
switch (_that) {
case _OrderDetail() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( OrderSummary summary,  PaymentMethodItem? paymentMethod,  double? balanceAmountYuan,  double? surplusAmountYuan,  double? discountAmountYuan,  double? handlingAmountYuan)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _OrderDetail() when $default != null:
return $default(_that.summary,_that.paymentMethod,_that.balanceAmountYuan,_that.surplusAmountYuan,_that.discountAmountYuan,_that.handlingAmountYuan);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( OrderSummary summary,  PaymentMethodItem? paymentMethod,  double? balanceAmountYuan,  double? surplusAmountYuan,  double? discountAmountYuan,  double? handlingAmountYuan)  $default,) {final _that = this;
switch (_that) {
case _OrderDetail():
return $default(_that.summary,_that.paymentMethod,_that.balanceAmountYuan,_that.surplusAmountYuan,_that.discountAmountYuan,_that.handlingAmountYuan);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( OrderSummary summary,  PaymentMethodItem? paymentMethod,  double? balanceAmountYuan,  double? surplusAmountYuan,  double? discountAmountYuan,  double? handlingAmountYuan)?  $default,) {final _that = this;
switch (_that) {
case _OrderDetail() when $default != null:
return $default(_that.summary,_that.paymentMethod,_that.balanceAmountYuan,_that.surplusAmountYuan,_that.discountAmountYuan,_that.handlingAmountYuan);case _:
  return null;

}
}

}

/// @nodoc


class _OrderDetail implements OrderDetail {
  const _OrderDetail({required this.summary, this.paymentMethod, this.balanceAmountYuan, this.surplusAmountYuan, this.discountAmountYuan, this.handlingAmountYuan});
  

@override final  OrderSummary summary;
@override final  PaymentMethodItem? paymentMethod;
@override final  double? balanceAmountYuan;
@override final  double? surplusAmountYuan;
@override final  double? discountAmountYuan;
@override final  double? handlingAmountYuan;

/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$OrderDetailCopyWith<_OrderDetail> get copyWith => __$OrderDetailCopyWithImpl<_OrderDetail>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _OrderDetail&&(identical(other.summary, summary) || other.summary == summary)&&(identical(other.paymentMethod, paymentMethod) || other.paymentMethod == paymentMethod)&&(identical(other.balanceAmountYuan, balanceAmountYuan) || other.balanceAmountYuan == balanceAmountYuan)&&(identical(other.surplusAmountYuan, surplusAmountYuan) || other.surplusAmountYuan == surplusAmountYuan)&&(identical(other.discountAmountYuan, discountAmountYuan) || other.discountAmountYuan == discountAmountYuan)&&(identical(other.handlingAmountYuan, handlingAmountYuan) || other.handlingAmountYuan == handlingAmountYuan));
}


@override
int get hashCode {
    return Object.hash(runtimeType,summary,paymentMethod,balanceAmountYuan,surplusAmountYuan,discountAmountYuan,handlingAmountYuan);
}

@override
String toString() {
    return 'OrderDetail(summary: $summary, paymentMethod: $paymentMethod, balanceAmountYuan: $balanceAmountYuan, surplusAmountYuan: $surplusAmountYuan, discountAmountYuan: $discountAmountYuan, handlingAmountYuan: $handlingAmountYuan)';
}


}

/// @nodoc
abstract mixin class _$OrderDetailCopyWith<$Res> implements $OrderDetailCopyWith<$Res> {
  factory _$OrderDetailCopyWith(_OrderDetail value, $Res Function(_OrderDetail) _then) = __$OrderDetailCopyWithImpl;
@override @useResult
$Res call({
 OrderSummary summary, PaymentMethodItem? paymentMethod, double? balanceAmountYuan, double? surplusAmountYuan, double? discountAmountYuan, double? handlingAmountYuan
});


@override $OrderSummaryCopyWith<$Res> get summary;@override $PaymentMethodItemCopyWith<$Res>? get paymentMethod;

}
/// @nodoc
class __$OrderDetailCopyWithImpl<$Res>
    implements _$OrderDetailCopyWith<$Res> {
  __$OrderDetailCopyWithImpl(this._self, this._then);

  final _OrderDetail _self;
  final $Res Function(_OrderDetail) _then;

/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? summary = null,Object? paymentMethod = freezed,Object? balanceAmountYuan = freezed,Object? surplusAmountYuan = freezed,Object? discountAmountYuan = freezed,Object? handlingAmountYuan = freezed,}) {
  return _then(_OrderDetail(
summary: null == summary ? _self.summary : summary // ignore: cast_nullable_to_non_nullable
as OrderSummary,paymentMethod: freezed == paymentMethod ? _self.paymentMethod : paymentMethod // ignore: cast_nullable_to_non_nullable
as PaymentMethodItem?,balanceAmountYuan: freezed == balanceAmountYuan ? _self.balanceAmountYuan : balanceAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,surplusAmountYuan: freezed == surplusAmountYuan ? _self.surplusAmountYuan : surplusAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,discountAmountYuan: freezed == discountAmountYuan ? _self.discountAmountYuan : discountAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,handlingAmountYuan: freezed == handlingAmountYuan ? _self.handlingAmountYuan : handlingAmountYuan // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}

/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$OrderSummaryCopyWith<$Res> get summary {
  
  return $OrderSummaryCopyWith<$Res>(_self.summary, (value) {
    return _then(_self.copyWith(summary: value));
  });
}/// Create a copy of OrderDetail
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PaymentMethodItemCopyWith<$Res>? get paymentMethod {
    if (_self.paymentMethod == null) {
    return null;
  }

  return $PaymentMethodItemCopyWith<$Res>(_self.paymentMethod!, (value) {
    return _then(_self.copyWith(paymentMethod: value));
  });
}
}

// dart format on
