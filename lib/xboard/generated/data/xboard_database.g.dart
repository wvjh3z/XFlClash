// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../data/xboard_database.dart';

// ignore_for_file: type=lint
class $XboardProfileIndexV1Table extends XboardProfileIndexV1
    with TableInfo<$XboardProfileIndexV1Table, XboardProfileIndexV1Data> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $XboardProfileIndexV1Table(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _flavorIdMeta = const VerificationMeta(
    'flavorId',
  );
  @override
  late final GeneratedColumn<String> flavorId = GeneratedColumn<String>(
    'flavor_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdHashMeta = const VerificationMeta(
    'userIdHash',
  );
  @override
  late final GeneratedColumn<String> userIdHash = GeneratedColumn<String>(
    'user_id_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [profileId, flavorId, userIdHash];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'xboard_profile_index_v1';
  @override
  VerificationContext validateIntegrity(
    Insertable<XboardProfileIndexV1Data> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    }
    if (data.containsKey('flavor_id')) {
      context.handle(
        _flavorIdMeta,
        flavorId.isAcceptableOrUnknown(data['flavor_id']!, _flavorIdMeta),
      );
    } else if (isInserting) {
      context.missing(_flavorIdMeta);
    }
    if (data.containsKey('user_id_hash')) {
      context.handle(
        _userIdHashMeta,
        userIdHash.isAcceptableOrUnknown(
          data['user_id_hash']!,
          _userIdHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_userIdHashMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId};
  @override
  XboardProfileIndexV1Data map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return XboardProfileIndexV1Data(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}profile_id'],
      )!,
      flavorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}flavor_id'],
      )!,
      userIdHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id_hash'],
      )!,
    );
  }

  @override
  $XboardProfileIndexV1Table createAlias(String alias) {
    return $XboardProfileIndexV1Table(attachedDatabase, alias);
  }
}

class XboardProfileIndexV1Data extends DataClass
    implements Insertable<XboardProfileIndexV1Data> {
  /// FlClash profile id（主键）。
  final int profileId;

  /// 所属 flavor（多 flavor 隔离）。
  final String flavorId;

  /// 用户 hash（token sha256 前缀；切账号天然区分，ε4）。
  final String userIdHash;
  const XboardProfileIndexV1Data({
    required this.profileId,
    required this.flavorId,
    required this.userIdHash,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<int>(profileId);
    map['flavor_id'] = Variable<String>(flavorId);
    map['user_id_hash'] = Variable<String>(userIdHash);
    return map;
  }

  XboardProfileIndexV1Companion toCompanion(bool nullToAbsent) {
    return XboardProfileIndexV1Companion(
      profileId: Value(profileId),
      flavorId: Value(flavorId),
      userIdHash: Value(userIdHash),
    );
  }

  factory XboardProfileIndexV1Data.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return XboardProfileIndexV1Data(
      profileId: serializer.fromJson<int>(json['profileId']),
      flavorId: serializer.fromJson<String>(json['flavorId']),
      userIdHash: serializer.fromJson<String>(json['userIdHash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<int>(profileId),
      'flavorId': serializer.toJson<String>(flavorId),
      'userIdHash': serializer.toJson<String>(userIdHash),
    };
  }

  XboardProfileIndexV1Data copyWith({
    int? profileId,
    String? flavorId,
    String? userIdHash,
  }) => XboardProfileIndexV1Data(
    profileId: profileId ?? this.profileId,
    flavorId: flavorId ?? this.flavorId,
    userIdHash: userIdHash ?? this.userIdHash,
  );
  XboardProfileIndexV1Data copyWithCompanion(
    XboardProfileIndexV1Companion data,
  ) {
    return XboardProfileIndexV1Data(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      flavorId: data.flavorId.present ? data.flavorId.value : this.flavorId,
      userIdHash: data.userIdHash.present
          ? data.userIdHash.value
          : this.userIdHash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('XboardProfileIndexV1Data(')
          ..write('profileId: $profileId, ')
          ..write('flavorId: $flavorId, ')
          ..write('userIdHash: $userIdHash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(profileId, flavorId, userIdHash);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is XboardProfileIndexV1Data &&
          other.profileId == this.profileId &&
          other.flavorId == this.flavorId &&
          other.userIdHash == this.userIdHash);
}

class XboardProfileIndexV1Companion
    extends UpdateCompanion<XboardProfileIndexV1Data> {
  final Value<int> profileId;
  final Value<String> flavorId;
  final Value<String> userIdHash;
  const XboardProfileIndexV1Companion({
    this.profileId = const Value.absent(),
    this.flavorId = const Value.absent(),
    this.userIdHash = const Value.absent(),
  });
  XboardProfileIndexV1Companion.insert({
    this.profileId = const Value.absent(),
    required String flavorId,
    required String userIdHash,
  }) : flavorId = Value(flavorId),
       userIdHash = Value(userIdHash);
  static Insertable<XboardProfileIndexV1Data> custom({
    Expression<int>? profileId,
    Expression<String>? flavorId,
    Expression<String>? userIdHash,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (flavorId != null) 'flavor_id': flavorId,
      if (userIdHash != null) 'user_id_hash': userIdHash,
    });
  }

  XboardProfileIndexV1Companion copyWith({
    Value<int>? profileId,
    Value<String>? flavorId,
    Value<String>? userIdHash,
  }) {
    return XboardProfileIndexV1Companion(
      profileId: profileId ?? this.profileId,
      flavorId: flavorId ?? this.flavorId,
      userIdHash: userIdHash ?? this.userIdHash,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<int>(profileId.value);
    }
    if (flavorId.present) {
      map['flavor_id'] = Variable<String>(flavorId.value);
    }
    if (userIdHash.present) {
      map['user_id_hash'] = Variable<String>(userIdHash.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('XboardProfileIndexV1Companion(')
          ..write('profileId: $profileId, ')
          ..write('flavorId: $flavorId, ')
          ..write('userIdHash: $userIdHash')
          ..write(')'))
        .toString();
  }
}

abstract class _$XboardDatabase extends GeneratedDatabase {
  _$XboardDatabase(QueryExecutor e) : super(e);
  $XboardDatabaseManager get managers => $XboardDatabaseManager(this);
  late final $XboardProfileIndexV1Table xboardProfileIndexV1 =
      $XboardProfileIndexV1Table(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [xboardProfileIndexV1];
}

typedef $$XboardProfileIndexV1TableCreateCompanionBuilder =
    XboardProfileIndexV1Companion Function({
      Value<int> profileId,
      required String flavorId,
      required String userIdHash,
    });
typedef $$XboardProfileIndexV1TableUpdateCompanionBuilder =
    XboardProfileIndexV1Companion Function({
      Value<int> profileId,
      Value<String> flavorId,
      Value<String> userIdHash,
    });

class $$XboardProfileIndexV1TableFilterComposer
    extends Composer<_$XboardDatabase, $XboardProfileIndexV1Table> {
  $$XboardProfileIndexV1TableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get flavorId => $composableBuilder(
    column: $table.flavorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userIdHash => $composableBuilder(
    column: $table.userIdHash,
    builder: (column) => ColumnFilters(column),
  );
}

class $$XboardProfileIndexV1TableOrderingComposer
    extends Composer<_$XboardDatabase, $XboardProfileIndexV1Table> {
  $$XboardProfileIndexV1TableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get flavorId => $composableBuilder(
    column: $table.flavorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userIdHash => $composableBuilder(
    column: $table.userIdHash,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$XboardProfileIndexV1TableAnnotationComposer
    extends Composer<_$XboardDatabase, $XboardProfileIndexV1Table> {
  $$XboardProfileIndexV1TableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get flavorId =>
      $composableBuilder(column: $table.flavorId, builder: (column) => column);

  GeneratedColumn<String> get userIdHash => $composableBuilder(
    column: $table.userIdHash,
    builder: (column) => column,
  );
}

class $$XboardProfileIndexV1TableTableManager
    extends
        RootTableManager<
          _$XboardDatabase,
          $XboardProfileIndexV1Table,
          XboardProfileIndexV1Data,
          $$XboardProfileIndexV1TableFilterComposer,
          $$XboardProfileIndexV1TableOrderingComposer,
          $$XboardProfileIndexV1TableAnnotationComposer,
          $$XboardProfileIndexV1TableCreateCompanionBuilder,
          $$XboardProfileIndexV1TableUpdateCompanionBuilder,
          (
            XboardProfileIndexV1Data,
            BaseReferences<
              _$XboardDatabase,
              $XboardProfileIndexV1Table,
              XboardProfileIndexV1Data
            >,
          ),
          XboardProfileIndexV1Data,
          PrefetchHooks Function()
        > {
  $$XboardProfileIndexV1TableTableManager(
    _$XboardDatabase db,
    $XboardProfileIndexV1Table table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$XboardProfileIndexV1TableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$XboardProfileIndexV1TableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$XboardProfileIndexV1TableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> profileId = const Value.absent(),
                Value<String> flavorId = const Value.absent(),
                Value<String> userIdHash = const Value.absent(),
              }) => XboardProfileIndexV1Companion(
                profileId: profileId,
                flavorId: flavorId,
                userIdHash: userIdHash,
              ),
          createCompanionCallback:
              ({
                Value<int> profileId = const Value.absent(),
                required String flavorId,
                required String userIdHash,
              }) => XboardProfileIndexV1Companion.insert(
                profileId: profileId,
                flavorId: flavorId,
                userIdHash: userIdHash,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$XboardProfileIndexV1TableProcessedTableManager =
    ProcessedTableManager<
      _$XboardDatabase,
      $XboardProfileIndexV1Table,
      XboardProfileIndexV1Data,
      $$XboardProfileIndexV1TableFilterComposer,
      $$XboardProfileIndexV1TableOrderingComposer,
      $$XboardProfileIndexV1TableAnnotationComposer,
      $$XboardProfileIndexV1TableCreateCompanionBuilder,
      $$XboardProfileIndexV1TableUpdateCompanionBuilder,
      (
        XboardProfileIndexV1Data,
        BaseReferences<
          _$XboardDatabase,
          $XboardProfileIndexV1Table,
          XboardProfileIndexV1Data
        >,
      ),
      XboardProfileIndexV1Data,
      PrefetchHooks Function()
    >;

class $XboardDatabaseManager {
  final _$XboardDatabase _db;
  $XboardDatabaseManager(this._db);
  $$XboardProfileIndexV1TableTableManager get xboardProfileIndexV1 =>
      $$XboardProfileIndexV1TableTableManager(_db, _db.xboardProfileIndexV1);
}
