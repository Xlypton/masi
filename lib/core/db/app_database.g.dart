// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $AreasTable extends Areas with TableInfo<$AreasTable, Area> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AreasTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accessStateMeta = const VerificationMeta(
    'accessState',
  );
  @override
  late final GeneratedColumn<String> accessState = GeneratedColumn<String>(
    'access_state',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accessNoteMeta = const VerificationMeta(
    'accessNote',
  );
  @override
  late final GeneratedColumn<String> accessNote = GeneratedColumn<String>(
    'access_note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _latitudeMeta = const VerificationMeta(
    'latitude',
  );
  @override
  late final GeneratedColumn<double> latitude = GeneratedColumn<double>(
    'latitude',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _longitudeMeta = const VerificationMeta(
    'longitude',
  );
  @override
  late final GeneratedColumn<double> longitude = GeneratedColumn<double>(
    'longitude',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    accessState,
    accessNote,
    name,
    description,
    latitude,
    longitude,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'areas';
  @override
  VerificationContext validateIntegrity(
    Insertable<Area> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('access_state')) {
      context.handle(
        _accessStateMeta,
        accessState.isAcceptableOrUnknown(
          data['access_state']!,
          _accessStateMeta,
        ),
      );
    }
    if (data.containsKey('access_note')) {
      context.handle(
        _accessNoteMeta,
        accessNote.isAcceptableOrUnknown(data['access_note']!, _accessNoteMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('latitude')) {
      context.handle(
        _latitudeMeta,
        latitude.isAcceptableOrUnknown(data['latitude']!, _latitudeMeta),
      );
    }
    if (data.containsKey('longitude')) {
      context.handle(
        _longitudeMeta,
        longitude.isAcceptableOrUnknown(data['longitude']!, _longitudeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Area map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Area(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      accessState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}access_state'],
      ),
      accessNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}access_note'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      latitude: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}latitude'],
      ),
      longitude: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}longitude'],
      ),
    );
  }

  @override
  $AreasTable createAlias(String alias) {
    return $AreasTable(attachedDatabase, alias);
  }
}

class Area extends DataClass implements Insertable<Area> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;
  final String? accessState;

  /// Free text explaining the restriction ("Peregrine nesting until 31 Jul",
  /// "Private land, ask at the farmhouse"). theCrag's model: state the reason,
  /// because a bare "closed" with no explanation gets ignored.
  final String? accessNote;
  final String name;
  final String? description;
  final double? latitude;
  final double? longitude;
  const Area({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    this.accessState,
    this.accessNote,
    required this.name,
    this.description,
    this.latitude,
    this.longitude,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || accessState != null) {
      map['access_state'] = Variable<String>(accessState);
    }
    if (!nullToAbsent || accessNote != null) {
      map['access_note'] = Variable<String>(accessNote);
    }
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    if (!nullToAbsent || latitude != null) {
      map['latitude'] = Variable<double>(latitude);
    }
    if (!nullToAbsent || longitude != null) {
      map['longitude'] = Variable<double>(longitude);
    }
    return map;
  }

  AreasCompanion toCompanion(bool nullToAbsent) {
    return AreasCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      accessState: accessState == null && nullToAbsent
          ? const Value.absent()
          : Value(accessState),
      accessNote: accessNote == null && nullToAbsent
          ? const Value.absent()
          : Value(accessNote),
      name: Value(name),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      latitude: latitude == null && nullToAbsent
          ? const Value.absent()
          : Value(latitude),
      longitude: longitude == null && nullToAbsent
          ? const Value.absent()
          : Value(longitude),
    );
  }

  factory Area.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Area(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      accessState: serializer.fromJson<String?>(json['accessState']),
      accessNote: serializer.fromJson<String?>(json['accessNote']),
      name: serializer.fromJson<String>(json['name']),
      description: serializer.fromJson<String?>(json['description']),
      latitude: serializer.fromJson<double?>(json['latitude']),
      longitude: serializer.fromJson<double?>(json['longitude']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'accessState': serializer.toJson<String?>(accessState),
      'accessNote': serializer.toJson<String?>(accessNote),
      'name': serializer.toJson<String>(name),
      'description': serializer.toJson<String?>(description),
      'latitude': serializer.toJson<double?>(latitude),
      'longitude': serializer.toJson<double?>(longitude),
    };
  }

  Area copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    Value<String?> accessState = const Value.absent(),
    Value<String?> accessNote = const Value.absent(),
    String? name,
    Value<String?> description = const Value.absent(),
    Value<double?> latitude = const Value.absent(),
    Value<double?> longitude = const Value.absent(),
  }) => Area(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    accessState: accessState.present ? accessState.value : this.accessState,
    accessNote: accessNote.present ? accessNote.value : this.accessNote,
    name: name ?? this.name,
    description: description.present ? description.value : this.description,
    latitude: latitude.present ? latitude.value : this.latitude,
    longitude: longitude.present ? longitude.value : this.longitude,
  );
  Area copyWithCompanion(AreasCompanion data) {
    return Area(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      accessState: data.accessState.present
          ? data.accessState.value
          : this.accessState,
      accessNote: data.accessNote.present
          ? data.accessNote.value
          : this.accessNote,
      name: data.name.present ? data.name.value : this.name,
      description: data.description.present
          ? data.description.value
          : this.description,
      latitude: data.latitude.present ? data.latitude.value : this.latitude,
      longitude: data.longitude.present ? data.longitude.value : this.longitude,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Area(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('accessState: $accessState, ')
          ..write('accessNote: $accessNote, ')
          ..write('name: $name, ')
          ..write('description: $description, ')
          ..write('latitude: $latitude, ')
          ..write('longitude: $longitude')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    accessState,
    accessNote,
    name,
    description,
    latitude,
    longitude,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Area &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.accessState == this.accessState &&
          other.accessNote == this.accessNote &&
          other.name == this.name &&
          other.description == this.description &&
          other.latitude == this.latitude &&
          other.longitude == this.longitude);
}

class AreasCompanion extends UpdateCompanion<Area> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String?> accessState;
  final Value<String?> accessNote;
  final Value<String> name;
  final Value<String?> description;
  final Value<double?> latitude;
  final Value<double?> longitude;
  final Value<int> rowid;
  const AreasCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.accessState = const Value.absent(),
    this.accessNote = const Value.absent(),
    this.name = const Value.absent(),
    this.description = const Value.absent(),
    this.latitude = const Value.absent(),
    this.longitude = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AreasCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.accessState = const Value.absent(),
    this.accessNote = const Value.absent(),
    required String name,
    this.description = const Value.absent(),
    this.latitude = const Value.absent(),
    this.longitude = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       name = Value(name);
  static Insertable<Area> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? accessState,
    Expression<String>? accessNote,
    Expression<String>? name,
    Expression<String>? description,
    Expression<double>? latitude,
    Expression<double>? longitude,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (accessState != null) 'access_state': accessState,
      if (accessNote != null) 'access_note': accessNote,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AreasCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String?>? accessState,
    Value<String?>? accessNote,
    Value<String>? name,
    Value<String?>? description,
    Value<double?>? latitude,
    Value<double?>? longitude,
    Value<int>? rowid,
  }) {
    return AreasCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      accessState: accessState ?? this.accessState,
      accessNote: accessNote ?? this.accessNote,
      name: name ?? this.name,
      description: description ?? this.description,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (accessState.present) {
      map['access_state'] = Variable<String>(accessState.value);
    }
    if (accessNote.present) {
      map['access_note'] = Variable<String>(accessNote.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (latitude.present) {
      map['latitude'] = Variable<double>(latitude.value);
    }
    if (longitude.present) {
      map['longitude'] = Variable<double>(longitude.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AreasCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('accessState: $accessState, ')
          ..write('accessNote: $accessNote, ')
          ..write('name: $name, ')
          ..write('description: $description, ')
          ..write('latitude: $latitude, ')
          ..write('longitude: $longitude, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SectorsTable extends Sectors with TableInfo<$SectorsTable, Sector> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SectorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accessStateMeta = const VerificationMeta(
    'accessState',
  );
  @override
  late final GeneratedColumn<String> accessState = GeneratedColumn<String>(
    'access_state',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accessNoteMeta = const VerificationMeta(
    'accessNote',
  );
  @override
  late final GeneratedColumn<String> accessNote = GeneratedColumn<String>(
    'access_note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _areaIdMeta = const VerificationMeta('areaId');
  @override
  late final GeneratedColumn<String> areaId = GeneratedColumn<String>(
    'area_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES areas (id)',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    accessState,
    accessNote,
    areaId,
    name,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sectors';
  @override
  VerificationContext validateIntegrity(
    Insertable<Sector> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('access_state')) {
      context.handle(
        _accessStateMeta,
        accessState.isAcceptableOrUnknown(
          data['access_state']!,
          _accessStateMeta,
        ),
      );
    }
    if (data.containsKey('access_note')) {
      context.handle(
        _accessNoteMeta,
        accessNote.isAcceptableOrUnknown(data['access_note']!, _accessNoteMeta),
      );
    }
    if (data.containsKey('area_id')) {
      context.handle(
        _areaIdMeta,
        areaId.isAcceptableOrUnknown(data['area_id']!, _areaIdMeta),
      );
    } else if (isInserting) {
      context.missing(_areaIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Sector map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Sector(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      accessState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}access_state'],
      ),
      accessNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}access_note'],
      ),
      areaId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}area_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $SectorsTable createAlias(String alias) {
    return $SectorsTable(attachedDatabase, alias);
  }
}

class Sector extends DataClass implements Insertable<Sector> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;
  final String? accessState;

  /// Free text explaining the restriction ("Peregrine nesting until 31 Jul",
  /// "Private land, ask at the farmhouse"). theCrag's model: state the reason,
  /// because a bare "closed" with no explanation gets ignored.
  final String? accessNote;
  final String areaId;
  final String name;
  final int sortOrder;
  const Sector({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    this.accessState,
    this.accessNote,
    required this.areaId,
    required this.name,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || accessState != null) {
      map['access_state'] = Variable<String>(accessState);
    }
    if (!nullToAbsent || accessNote != null) {
      map['access_note'] = Variable<String>(accessNote);
    }
    map['area_id'] = Variable<String>(areaId);
    map['name'] = Variable<String>(name);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  SectorsCompanion toCompanion(bool nullToAbsent) {
    return SectorsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      accessState: accessState == null && nullToAbsent
          ? const Value.absent()
          : Value(accessState),
      accessNote: accessNote == null && nullToAbsent
          ? const Value.absent()
          : Value(accessNote),
      areaId: Value(areaId),
      name: Value(name),
      sortOrder: Value(sortOrder),
    );
  }

  factory Sector.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Sector(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      accessState: serializer.fromJson<String?>(json['accessState']),
      accessNote: serializer.fromJson<String?>(json['accessNote']),
      areaId: serializer.fromJson<String>(json['areaId']),
      name: serializer.fromJson<String>(json['name']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'accessState': serializer.toJson<String?>(accessState),
      'accessNote': serializer.toJson<String?>(accessNote),
      'areaId': serializer.toJson<String>(areaId),
      'name': serializer.toJson<String>(name),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  Sector copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    Value<String?> accessState = const Value.absent(),
    Value<String?> accessNote = const Value.absent(),
    String? areaId,
    String? name,
    int? sortOrder,
  }) => Sector(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    accessState: accessState.present ? accessState.value : this.accessState,
    accessNote: accessNote.present ? accessNote.value : this.accessNote,
    areaId: areaId ?? this.areaId,
    name: name ?? this.name,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  Sector copyWithCompanion(SectorsCompanion data) {
    return Sector(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      accessState: data.accessState.present
          ? data.accessState.value
          : this.accessState,
      accessNote: data.accessNote.present
          ? data.accessNote.value
          : this.accessNote,
      areaId: data.areaId.present ? data.areaId.value : this.areaId,
      name: data.name.present ? data.name.value : this.name,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Sector(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('accessState: $accessState, ')
          ..write('accessNote: $accessNote, ')
          ..write('areaId: $areaId, ')
          ..write('name: $name, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    accessState,
    accessNote,
    areaId,
    name,
    sortOrder,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Sector &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.accessState == this.accessState &&
          other.accessNote == this.accessNote &&
          other.areaId == this.areaId &&
          other.name == this.name &&
          other.sortOrder == this.sortOrder);
}

class SectorsCompanion extends UpdateCompanion<Sector> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String?> accessState;
  final Value<String?> accessNote;
  final Value<String> areaId;
  final Value<String> name;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const SectorsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.accessState = const Value.absent(),
    this.accessNote = const Value.absent(),
    this.areaId = const Value.absent(),
    this.name = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SectorsCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.accessState = const Value.absent(),
    this.accessNote = const Value.absent(),
    required String areaId,
    required String name,
    required int sortOrder,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       areaId = Value(areaId),
       name = Value(name),
       sortOrder = Value(sortOrder);
  static Insertable<Sector> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? accessState,
    Expression<String>? accessNote,
    Expression<String>? areaId,
    Expression<String>? name,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (accessState != null) 'access_state': accessState,
      if (accessNote != null) 'access_note': accessNote,
      if (areaId != null) 'area_id': areaId,
      if (name != null) 'name': name,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SectorsCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String?>? accessState,
    Value<String?>? accessNote,
    Value<String>? areaId,
    Value<String>? name,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return SectorsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      accessState: accessState ?? this.accessState,
      accessNote: accessNote ?? this.accessNote,
      areaId: areaId ?? this.areaId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (accessState.present) {
      map['access_state'] = Variable<String>(accessState.value);
    }
    if (accessNote.present) {
      map['access_note'] = Variable<String>(accessNote.value);
    }
    if (areaId.present) {
      map['area_id'] = Variable<String>(areaId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SectorsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('accessState: $accessState, ')
          ..write('accessNote: $accessNote, ')
          ..write('areaId: $areaId, ')
          ..write('name: $name, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WallsTable extends Walls with TableInfo<$WallsTable, Wall> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WallsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accessStateMeta = const VerificationMeta(
    'accessState',
  );
  @override
  late final GeneratedColumn<String> accessState = GeneratedColumn<String>(
    'access_state',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accessNoteMeta = const VerificationMeta(
    'accessNote',
  );
  @override
  late final GeneratedColumn<String> accessNote = GeneratedColumn<String>(
    'access_note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sectorIdMeta = const VerificationMeta(
    'sectorId',
  );
  @override
  late final GeneratedColumn<String> sectorId = GeneratedColumn<String>(
    'sector_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sectors (id)',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _visibilityMeta = const VerificationMeta(
    'visibility',
  );
  @override
  late final GeneratedColumn<String> visibility = GeneratedColumn<String>(
    'visibility',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('private'),
  );
  static const VerificationMeta _latitudeMeta = const VerificationMeta(
    'latitude',
  );
  @override
  late final GeneratedColumn<double> latitude = GeneratedColumn<double>(
    'latitude',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _longitudeMeta = const VerificationMeta(
    'longitude',
  );
  @override
  late final GeneratedColumn<double> longitude = GeneratedColumn<double>(
    'longitude',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baselineJsonMeta = const VerificationMeta(
    'baselineJson',
  );
  @override
  late final GeneratedColumn<String> baselineJson = GeneratedColumn<String>(
    'baseline_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    accessState,
    accessNote,
    sectorId,
    name,
    sortOrder,
    visibility,
    latitude,
    longitude,
    baselineJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'walls';
  @override
  VerificationContext validateIntegrity(
    Insertable<Wall> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('access_state')) {
      context.handle(
        _accessStateMeta,
        accessState.isAcceptableOrUnknown(
          data['access_state']!,
          _accessStateMeta,
        ),
      );
    }
    if (data.containsKey('access_note')) {
      context.handle(
        _accessNoteMeta,
        accessNote.isAcceptableOrUnknown(data['access_note']!, _accessNoteMeta),
      );
    }
    if (data.containsKey('sector_id')) {
      context.handle(
        _sectorIdMeta,
        sectorId.isAcceptableOrUnknown(data['sector_id']!, _sectorIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sectorIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    if (data.containsKey('visibility')) {
      context.handle(
        _visibilityMeta,
        visibility.isAcceptableOrUnknown(data['visibility']!, _visibilityMeta),
      );
    }
    if (data.containsKey('latitude')) {
      context.handle(
        _latitudeMeta,
        latitude.isAcceptableOrUnknown(data['latitude']!, _latitudeMeta),
      );
    }
    if (data.containsKey('longitude')) {
      context.handle(
        _longitudeMeta,
        longitude.isAcceptableOrUnknown(data['longitude']!, _longitudeMeta),
      );
    }
    if (data.containsKey('baseline_json')) {
      context.handle(
        _baselineJsonMeta,
        baselineJson.isAcceptableOrUnknown(
          data['baseline_json']!,
          _baselineJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Wall map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Wall(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      accessState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}access_state'],
      ),
      accessNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}access_note'],
      ),
      sectorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sector_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      visibility: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}visibility'],
      )!,
      latitude: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}latitude'],
      ),
      longitude: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}longitude'],
      ),
      baselineJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}baseline_json'],
      ),
    );
  }

  @override
  $WallsTable createAlias(String alias) {
    return $WallsTable(attachedDatabase, alias);
  }
}

class Wall extends DataClass implements Insertable<Wall> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;
  final String? accessState;

  /// Free text explaining the restriction ("Peregrine nesting until 31 Jul",
  /// "Private land, ask at the farmhouse"). theCrag's model: state the reason,
  /// because a bare "closed" with no explanation gets ignored.
  final String? accessNote;
  final String sectorId;
  final String name;
  final int sortOrder;

  /// Cloud-sharing visibility for this wall (a "topo"): `'private'` (default;
  /// visible only to its owner) or `'shared'`. Deliberately separate from
  /// [Routes.visible], which is a per-route render show/hide flag, not a
  /// sharing concept.
  final String visibility;

  /// GPS coordinates for this wall/topo, captured automatically from a
  /// freshly-picked photo's EXIF GPS tags (see `core/location/photo_gps.dart`'s
  /// `extractGpsFromImageBytes` and `LibraryCrudRepository.setWallCoordinates`)
  /// — `null` until a photo with GPS EXIF has been attached. Unlike
  /// [Areas.latitude]/[Areas.longitude] (manually set, never actually
  /// populated by any UI as of v3), these are meant to be populated
  /// automatically and back the Community map (see `CommunityRepository.
  /// watchSharedTopos`).
  final double? latitude;
  final double? longitude;

  /// The wall's semantic baseline — the rock's footprint seen from above, as
  /// the JSON written by `face_layout/baseline.dart`'s `Baseline.encode`
  /// (a polyline in metres east/north of [latitude]/[longitude], plus whether
  /// it closes).
  ///
  /// `null` means nobody has authored one, NOT that the wall has no layout: a
  /// provisional line is synthesised from the photos' own GPS and headings on
  /// every read (`resolveLayout`), so a contributor who does nothing still
  /// gets an arranged topo. Storing only the AUTHORED stroke is what makes
  /// that possible — a stored provisional one would freeze a guess made
  /// before half the photos existed, and §5's "recompute on every edit" could
  /// never improve it.
  ///
  /// Whether the stroke closes is the only thing separating a boulder from a
  /// wall in this model, which is why nothing in the UI ever asks.
  final String? baselineJson;
  const Wall({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    this.accessState,
    this.accessNote,
    required this.sectorId,
    required this.name,
    required this.sortOrder,
    required this.visibility,
    this.latitude,
    this.longitude,
    this.baselineJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || accessState != null) {
      map['access_state'] = Variable<String>(accessState);
    }
    if (!nullToAbsent || accessNote != null) {
      map['access_note'] = Variable<String>(accessNote);
    }
    map['sector_id'] = Variable<String>(sectorId);
    map['name'] = Variable<String>(name);
    map['sort_order'] = Variable<int>(sortOrder);
    map['visibility'] = Variable<String>(visibility);
    if (!nullToAbsent || latitude != null) {
      map['latitude'] = Variable<double>(latitude);
    }
    if (!nullToAbsent || longitude != null) {
      map['longitude'] = Variable<double>(longitude);
    }
    if (!nullToAbsent || baselineJson != null) {
      map['baseline_json'] = Variable<String>(baselineJson);
    }
    return map;
  }

  WallsCompanion toCompanion(bool nullToAbsent) {
    return WallsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      accessState: accessState == null && nullToAbsent
          ? const Value.absent()
          : Value(accessState),
      accessNote: accessNote == null && nullToAbsent
          ? const Value.absent()
          : Value(accessNote),
      sectorId: Value(sectorId),
      name: Value(name),
      sortOrder: Value(sortOrder),
      visibility: Value(visibility),
      latitude: latitude == null && nullToAbsent
          ? const Value.absent()
          : Value(latitude),
      longitude: longitude == null && nullToAbsent
          ? const Value.absent()
          : Value(longitude),
      baselineJson: baselineJson == null && nullToAbsent
          ? const Value.absent()
          : Value(baselineJson),
    );
  }

  factory Wall.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Wall(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      accessState: serializer.fromJson<String?>(json['accessState']),
      accessNote: serializer.fromJson<String?>(json['accessNote']),
      sectorId: serializer.fromJson<String>(json['sectorId']),
      name: serializer.fromJson<String>(json['name']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      visibility: serializer.fromJson<String>(json['visibility']),
      latitude: serializer.fromJson<double?>(json['latitude']),
      longitude: serializer.fromJson<double?>(json['longitude']),
      baselineJson: serializer.fromJson<String?>(json['baselineJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'accessState': serializer.toJson<String?>(accessState),
      'accessNote': serializer.toJson<String?>(accessNote),
      'sectorId': serializer.toJson<String>(sectorId),
      'name': serializer.toJson<String>(name),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'visibility': serializer.toJson<String>(visibility),
      'latitude': serializer.toJson<double?>(latitude),
      'longitude': serializer.toJson<double?>(longitude),
      'baselineJson': serializer.toJson<String?>(baselineJson),
    };
  }

  Wall copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    Value<String?> accessState = const Value.absent(),
    Value<String?> accessNote = const Value.absent(),
    String? sectorId,
    String? name,
    int? sortOrder,
    String? visibility,
    Value<double?> latitude = const Value.absent(),
    Value<double?> longitude = const Value.absent(),
    Value<String?> baselineJson = const Value.absent(),
  }) => Wall(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    accessState: accessState.present ? accessState.value : this.accessState,
    accessNote: accessNote.present ? accessNote.value : this.accessNote,
    sectorId: sectorId ?? this.sectorId,
    name: name ?? this.name,
    sortOrder: sortOrder ?? this.sortOrder,
    visibility: visibility ?? this.visibility,
    latitude: latitude.present ? latitude.value : this.latitude,
    longitude: longitude.present ? longitude.value : this.longitude,
    baselineJson: baselineJson.present ? baselineJson.value : this.baselineJson,
  );
  Wall copyWithCompanion(WallsCompanion data) {
    return Wall(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      accessState: data.accessState.present
          ? data.accessState.value
          : this.accessState,
      accessNote: data.accessNote.present
          ? data.accessNote.value
          : this.accessNote,
      sectorId: data.sectorId.present ? data.sectorId.value : this.sectorId,
      name: data.name.present ? data.name.value : this.name,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      visibility: data.visibility.present
          ? data.visibility.value
          : this.visibility,
      latitude: data.latitude.present ? data.latitude.value : this.latitude,
      longitude: data.longitude.present ? data.longitude.value : this.longitude,
      baselineJson: data.baselineJson.present
          ? data.baselineJson.value
          : this.baselineJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Wall(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('accessState: $accessState, ')
          ..write('accessNote: $accessNote, ')
          ..write('sectorId: $sectorId, ')
          ..write('name: $name, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('visibility: $visibility, ')
          ..write('latitude: $latitude, ')
          ..write('longitude: $longitude, ')
          ..write('baselineJson: $baselineJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    accessState,
    accessNote,
    sectorId,
    name,
    sortOrder,
    visibility,
    latitude,
    longitude,
    baselineJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Wall &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.accessState == this.accessState &&
          other.accessNote == this.accessNote &&
          other.sectorId == this.sectorId &&
          other.name == this.name &&
          other.sortOrder == this.sortOrder &&
          other.visibility == this.visibility &&
          other.latitude == this.latitude &&
          other.longitude == this.longitude &&
          other.baselineJson == this.baselineJson);
}

class WallsCompanion extends UpdateCompanion<Wall> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String?> accessState;
  final Value<String?> accessNote;
  final Value<String> sectorId;
  final Value<String> name;
  final Value<int> sortOrder;
  final Value<String> visibility;
  final Value<double?> latitude;
  final Value<double?> longitude;
  final Value<String?> baselineJson;
  final Value<int> rowid;
  const WallsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.accessState = const Value.absent(),
    this.accessNote = const Value.absent(),
    this.sectorId = const Value.absent(),
    this.name = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.visibility = const Value.absent(),
    this.latitude = const Value.absent(),
    this.longitude = const Value.absent(),
    this.baselineJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WallsCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.accessState = const Value.absent(),
    this.accessNote = const Value.absent(),
    required String sectorId,
    required String name,
    required int sortOrder,
    this.visibility = const Value.absent(),
    this.latitude = const Value.absent(),
    this.longitude = const Value.absent(),
    this.baselineJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       sectorId = Value(sectorId),
       name = Value(name),
       sortOrder = Value(sortOrder);
  static Insertable<Wall> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? accessState,
    Expression<String>? accessNote,
    Expression<String>? sectorId,
    Expression<String>? name,
    Expression<int>? sortOrder,
    Expression<String>? visibility,
    Expression<double>? latitude,
    Expression<double>? longitude,
    Expression<String>? baselineJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (accessState != null) 'access_state': accessState,
      if (accessNote != null) 'access_note': accessNote,
      if (sectorId != null) 'sector_id': sectorId,
      if (name != null) 'name': name,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (visibility != null) 'visibility': visibility,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (baselineJson != null) 'baseline_json': baselineJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WallsCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String?>? accessState,
    Value<String?>? accessNote,
    Value<String>? sectorId,
    Value<String>? name,
    Value<int>? sortOrder,
    Value<String>? visibility,
    Value<double?>? latitude,
    Value<double?>? longitude,
    Value<String?>? baselineJson,
    Value<int>? rowid,
  }) {
    return WallsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      accessState: accessState ?? this.accessState,
      accessNote: accessNote ?? this.accessNote,
      sectorId: sectorId ?? this.sectorId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      visibility: visibility ?? this.visibility,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      baselineJson: baselineJson ?? this.baselineJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (accessState.present) {
      map['access_state'] = Variable<String>(accessState.value);
    }
    if (accessNote.present) {
      map['access_note'] = Variable<String>(accessNote.value);
    }
    if (sectorId.present) {
      map['sector_id'] = Variable<String>(sectorId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (visibility.present) {
      map['visibility'] = Variable<String>(visibility.value);
    }
    if (latitude.present) {
      map['latitude'] = Variable<double>(latitude.value);
    }
    if (longitude.present) {
      map['longitude'] = Variable<double>(longitude.value);
    }
    if (baselineJson.present) {
      map['baseline_json'] = Variable<String>(baselineJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WallsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('accessState: $accessState, ')
          ..write('accessNote: $accessNote, ')
          ..write('sectorId: $sectorId, ')
          ..write('name: $name, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('visibility: $visibility, ')
          ..write('latitude: $latitude, ')
          ..write('longitude: $longitude, ')
          ..write('baselineJson: $baselineJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PhotosTable extends Photos with TableInfo<$PhotosTable, Photo> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PhotosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES walls (id)',
    ),
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentPhotoIdMeta = const VerificationMeta(
    'parentPhotoId',
  );
  @override
  late final GeneratedColumn<String> parentPhotoId = GeneratedColumn<String>(
    'parent_photo_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES photos (id)',
    ),
  );
  static const VerificationMeta _cropXpctMeta = const VerificationMeta(
    'cropXpct',
  );
  @override
  late final GeneratedColumn<double> cropXpct = GeneratedColumn<double>(
    'crop_xpct',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cropWidthPctMeta = const VerificationMeta(
    'cropWidthPct',
  );
  @override
  late final GeneratedColumn<double> cropWidthPct = GeneratedColumn<double>(
    'crop_width_pct',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isPrimaryMeta = const VerificationMeta(
    'isPrimary',
  );
  @override
  late final GeneratedColumn<bool> isPrimary = GeneratedColumn<bool>(
    'is_primary',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_primary" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _captureLatitudeMeta = const VerificationMeta(
    'captureLatitude',
  );
  @override
  late final GeneratedColumn<double> captureLatitude = GeneratedColumn<double>(
    'capture_latitude',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _captureLongitudeMeta = const VerificationMeta(
    'captureLongitude',
  );
  @override
  late final GeneratedColumn<double> captureLongitude = GeneratedColumn<double>(
    'capture_longitude',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _captureAccuracyMetersMeta =
      const VerificationMeta('captureAccuracyMeters');
  @override
  late final GeneratedColumn<double> captureAccuracyMeters =
      GeneratedColumn<double>(
        'capture_accuracy_meters',
        aliasedName,
        true,
        type: DriftSqlType.double,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _captureBearingDegreesMeta =
      const VerificationMeta('captureBearingDegrees');
  @override
  late final GeneratedColumn<double> captureBearingDegrees =
      GeneratedColumn<double>(
        'capture_bearing_degrees',
        aliasedName,
        true,
        type: DriftSqlType.double,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _layoutPinnedTMeta = const VerificationMeta(
    'layoutPinnedT',
  );
  @override
  late final GeneratedColumn<double> layoutPinnedT = GeneratedColumn<double>(
    'layout_pinned_t',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    localPath,
    kind,
    width,
    height,
    parentPhotoId,
    cropXpct,
    cropWidthPct,
    sortOrder,
    isPrimary,
    captureLatitude,
    captureLongitude,
    captureAccuracyMeters,
    captureBearingDegrees,
    layoutPinnedT,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'photos';
  @override
  VerificationContext validateIntegrity(
    Insertable<Photo> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    } else if (isInserting) {
      context.missing(_wallIdMeta);
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    } else if (isInserting) {
      context.missing(_localPathMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    } else if (isInserting) {
      context.missing(_widthMeta);
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    } else if (isInserting) {
      context.missing(_heightMeta);
    }
    if (data.containsKey('parent_photo_id')) {
      context.handle(
        _parentPhotoIdMeta,
        parentPhotoId.isAcceptableOrUnknown(
          data['parent_photo_id']!,
          _parentPhotoIdMeta,
        ),
      );
    }
    if (data.containsKey('crop_xpct')) {
      context.handle(
        _cropXpctMeta,
        cropXpct.isAcceptableOrUnknown(data['crop_xpct']!, _cropXpctMeta),
      );
    }
    if (data.containsKey('crop_width_pct')) {
      context.handle(
        _cropWidthPctMeta,
        cropWidthPct.isAcceptableOrUnknown(
          data['crop_width_pct']!,
          _cropWidthPctMeta,
        ),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('is_primary')) {
      context.handle(
        _isPrimaryMeta,
        isPrimary.isAcceptableOrUnknown(data['is_primary']!, _isPrimaryMeta),
      );
    }
    if (data.containsKey('capture_latitude')) {
      context.handle(
        _captureLatitudeMeta,
        captureLatitude.isAcceptableOrUnknown(
          data['capture_latitude']!,
          _captureLatitudeMeta,
        ),
      );
    }
    if (data.containsKey('capture_longitude')) {
      context.handle(
        _captureLongitudeMeta,
        captureLongitude.isAcceptableOrUnknown(
          data['capture_longitude']!,
          _captureLongitudeMeta,
        ),
      );
    }
    if (data.containsKey('capture_accuracy_meters')) {
      context.handle(
        _captureAccuracyMetersMeta,
        captureAccuracyMeters.isAcceptableOrUnknown(
          data['capture_accuracy_meters']!,
          _captureAccuracyMetersMeta,
        ),
      );
    }
    if (data.containsKey('capture_bearing_degrees')) {
      context.handle(
        _captureBearingDegreesMeta,
        captureBearingDegrees.isAcceptableOrUnknown(
          data['capture_bearing_degrees']!,
          _captureBearingDegreesMeta,
        ),
      );
    }
    if (data.containsKey('layout_pinned_t')) {
      context.handle(
        _layoutPinnedTMeta,
        layoutPinnedT.isAcceptableOrUnknown(
          data['layout_pinned_t']!,
          _layoutPinnedTMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Photo map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Photo(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      )!,
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      )!,
      parentPhotoId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_photo_id'],
      ),
      cropXpct: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}crop_xpct'],
      ),
      cropWidthPct: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}crop_width_pct'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      isPrimary: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_primary'],
      )!,
      captureLatitude: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}capture_latitude'],
      ),
      captureLongitude: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}capture_longitude'],
      ),
      captureAccuracyMeters: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}capture_accuracy_meters'],
      ),
      captureBearingDegrees: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}capture_bearing_degrees'],
      ),
      layoutPinnedT: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}layout_pinned_t'],
      ),
    );
  }

  @override
  $PhotosTable createAlias(String alias) {
    return $PhotosTable(attachedDatabase, alias);
  }
}

class Photo extends DataClass implements Insertable<Photo> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;
  final String wallId;
  final String localPath;
  final String kind;
  final int width;
  final int height;
  final String? parentPhotoId;

  /// DEPRECATED/DORMANT (slice feature removed 2026-07-20): only ever
  /// populated on legacy `kind:'slice'` rows, which are no longer created or
  /// read by any code path. Left in place (nullable, unused) rather than
  /// dropped, to avoid a Drift table-recreate migration for two columns that
  /// cost nothing sitting idle. Do not read or write these in new code.
  final double? cropXpct;

  /// DEPRECATED/DORMANT — see [cropXpct].
  final double? cropWidthPct;

  /// Display order among a wall's live `kind:'original'` photos (the
  /// multi-photo-per-topo strip) — 0-based, ascending. Backfilled ascending
  /// by `createdAt` for pre-existing rows by the v5->v6 migration (see
  /// `app_database.dart`); set by `LibraryCrudRepository.attachPhotoToWall`
  /// (append-at-end) and `PhotoRepository.setPhotoOrder` (explicit reorder)
  /// thereafter.
  final int sortOrder;

  /// Whether this is the wall's PRIMARY original — the one shown as the
  /// topo's thumbnail ([LibraryCrudRepository.watchTopos]) and returned by
  /// [PhotoRepository.loadOriginal] (the canvas's default photo to open).
  /// At most one live original per wall should ever have this `true` (the
  /// single-primary invariant enforced by
  /// [PhotoRepository.setPrimaryPhoto]/[PhotoRepository.deleteOriginalPhoto]
  /// and by [LibraryCrudRepository.attachPhotoToWall], which only flags a
  /// freshly-attached photo primary when the wall has no live original yet).
  /// Backfilled by the v5->v6 migration: the newest (max `createdAt`) live
  /// original on each wall is flagged primary — this SAFELY resolves the
  /// #46 bug's accumulated multi-original walls without deleting any row.
  final bool isPrimary;

  /// Where this photo was taken, from its own EXIF GPS — the FACE-level fix,
  /// deliberately distinct from [Walls.latitude]/[Walls.longitude], which is
  /// the object-level pin shown on the map.
  ///
  /// The split is the whole of the layout spec's §5 signal hierarchy in two
  /// columns. A fix that is 10 m out is useless for saying which side of a
  /// 4 m boulder you are on and perfectly good for saying which valley the
  /// boulder is in; keeping one number for each question means no code can
  /// accidentally answer one with the other.
  final double? captureLatitude;
  final double? captureLongitude;

  /// Reported horizontal accuracy of that fix, in metres, or `null` when the
  /// photo did not say.
  ///
  /// `null` is treated as UNUSABLE rather than perfect (`FaceInput
  /// .hasUsableGps`). An unlabelled fix taken under a cliff is exactly the
  /// multipath case the hierarchy exists to distrust, and defaulting it to
  /// "good" would let the worst data outrank capture order.
  final double? captureAccuracyMeters;

  /// Camera heading in degrees clockwise from true north, from EXIF
  /// `GPSImgDirection`, or `null` — which is the common case, since many
  /// phones and most cameras write no heading at all.
  ///
  /// A hint and a sort key, never ground truth: iron-bearing rock and
  /// magnetic cases throw a magnetometer far enough off that a heading is
  /// only ever allowed to REFINE spacing, and any heading contradicting
  /// capture order is dropped as an outlier.
  final double? captureBearingDegrees;

  /// Where a human dragged this face to on the wall's baseline, as an
  /// arc-length fraction, or `null` if nobody has.
  ///
  /// One nullable column rather than the spec's `t` + `t_pinned` pair. The
  /// pair has a state nothing can arbitrate — a `t` with `t_pinned` false is
  /// a stale computed value — and full-row last-writer-wins sync (decision
  /// D-4) can land the two halves from different edits, producing a pin at a
  /// position nobody chose. A single nullable value cannot disagree with
  /// itself, and "unpinned" becomes the absence of a fact rather than a
  /// stored one.
  ///
  /// Authoritative once set: the resolver never overrides it, and every
  /// unpinned neighbour re-interpolates around it.
  final double? layoutPinnedT;
  const Photo({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    required this.wallId,
    required this.localPath,
    required this.kind,
    required this.width,
    required this.height,
    this.parentPhotoId,
    this.cropXpct,
    this.cropWidthPct,
    required this.sortOrder,
    required this.isPrimary,
    this.captureLatitude,
    this.captureLongitude,
    this.captureAccuracyMeters,
    this.captureBearingDegrees,
    this.layoutPinnedT,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    map['wall_id'] = Variable<String>(wallId);
    map['local_path'] = Variable<String>(localPath);
    map['kind'] = Variable<String>(kind);
    map['width'] = Variable<int>(width);
    map['height'] = Variable<int>(height);
    if (!nullToAbsent || parentPhotoId != null) {
      map['parent_photo_id'] = Variable<String>(parentPhotoId);
    }
    if (!nullToAbsent || cropXpct != null) {
      map['crop_xpct'] = Variable<double>(cropXpct);
    }
    if (!nullToAbsent || cropWidthPct != null) {
      map['crop_width_pct'] = Variable<double>(cropWidthPct);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    map['is_primary'] = Variable<bool>(isPrimary);
    if (!nullToAbsent || captureLatitude != null) {
      map['capture_latitude'] = Variable<double>(captureLatitude);
    }
    if (!nullToAbsent || captureLongitude != null) {
      map['capture_longitude'] = Variable<double>(captureLongitude);
    }
    if (!nullToAbsent || captureAccuracyMeters != null) {
      map['capture_accuracy_meters'] = Variable<double>(captureAccuracyMeters);
    }
    if (!nullToAbsent || captureBearingDegrees != null) {
      map['capture_bearing_degrees'] = Variable<double>(captureBearingDegrees);
    }
    if (!nullToAbsent || layoutPinnedT != null) {
      map['layout_pinned_t'] = Variable<double>(layoutPinnedT);
    }
    return map;
  }

  PhotosCompanion toCompanion(bool nullToAbsent) {
    return PhotosCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      wallId: Value(wallId),
      localPath: Value(localPath),
      kind: Value(kind),
      width: Value(width),
      height: Value(height),
      parentPhotoId: parentPhotoId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentPhotoId),
      cropXpct: cropXpct == null && nullToAbsent
          ? const Value.absent()
          : Value(cropXpct),
      cropWidthPct: cropWidthPct == null && nullToAbsent
          ? const Value.absent()
          : Value(cropWidthPct),
      sortOrder: Value(sortOrder),
      isPrimary: Value(isPrimary),
      captureLatitude: captureLatitude == null && nullToAbsent
          ? const Value.absent()
          : Value(captureLatitude),
      captureLongitude: captureLongitude == null && nullToAbsent
          ? const Value.absent()
          : Value(captureLongitude),
      captureAccuracyMeters: captureAccuracyMeters == null && nullToAbsent
          ? const Value.absent()
          : Value(captureAccuracyMeters),
      captureBearingDegrees: captureBearingDegrees == null && nullToAbsent
          ? const Value.absent()
          : Value(captureBearingDegrees),
      layoutPinnedT: layoutPinnedT == null && nullToAbsent
          ? const Value.absent()
          : Value(layoutPinnedT),
    );
  }

  factory Photo.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Photo(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      wallId: serializer.fromJson<String>(json['wallId']),
      localPath: serializer.fromJson<String>(json['localPath']),
      kind: serializer.fromJson<String>(json['kind']),
      width: serializer.fromJson<int>(json['width']),
      height: serializer.fromJson<int>(json['height']),
      parentPhotoId: serializer.fromJson<String?>(json['parentPhotoId']),
      cropXpct: serializer.fromJson<double?>(json['cropXpct']),
      cropWidthPct: serializer.fromJson<double?>(json['cropWidthPct']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      isPrimary: serializer.fromJson<bool>(json['isPrimary']),
      captureLatitude: serializer.fromJson<double?>(json['captureLatitude']),
      captureLongitude: serializer.fromJson<double?>(json['captureLongitude']),
      captureAccuracyMeters: serializer.fromJson<double?>(
        json['captureAccuracyMeters'],
      ),
      captureBearingDegrees: serializer.fromJson<double?>(
        json['captureBearingDegrees'],
      ),
      layoutPinnedT: serializer.fromJson<double?>(json['layoutPinnedT']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'wallId': serializer.toJson<String>(wallId),
      'localPath': serializer.toJson<String>(localPath),
      'kind': serializer.toJson<String>(kind),
      'width': serializer.toJson<int>(width),
      'height': serializer.toJson<int>(height),
      'parentPhotoId': serializer.toJson<String?>(parentPhotoId),
      'cropXpct': serializer.toJson<double?>(cropXpct),
      'cropWidthPct': serializer.toJson<double?>(cropWidthPct),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'isPrimary': serializer.toJson<bool>(isPrimary),
      'captureLatitude': serializer.toJson<double?>(captureLatitude),
      'captureLongitude': serializer.toJson<double?>(captureLongitude),
      'captureAccuracyMeters': serializer.toJson<double?>(
        captureAccuracyMeters,
      ),
      'captureBearingDegrees': serializer.toJson<double?>(
        captureBearingDegrees,
      ),
      'layoutPinnedT': serializer.toJson<double?>(layoutPinnedT),
    };
  }

  Photo copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    String? wallId,
    String? localPath,
    String? kind,
    int? width,
    int? height,
    Value<String?> parentPhotoId = const Value.absent(),
    Value<double?> cropXpct = const Value.absent(),
    Value<double?> cropWidthPct = const Value.absent(),
    int? sortOrder,
    bool? isPrimary,
    Value<double?> captureLatitude = const Value.absent(),
    Value<double?> captureLongitude = const Value.absent(),
    Value<double?> captureAccuracyMeters = const Value.absent(),
    Value<double?> captureBearingDegrees = const Value.absent(),
    Value<double?> layoutPinnedT = const Value.absent(),
  }) => Photo(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    wallId: wallId ?? this.wallId,
    localPath: localPath ?? this.localPath,
    kind: kind ?? this.kind,
    width: width ?? this.width,
    height: height ?? this.height,
    parentPhotoId: parentPhotoId.present
        ? parentPhotoId.value
        : this.parentPhotoId,
    cropXpct: cropXpct.present ? cropXpct.value : this.cropXpct,
    cropWidthPct: cropWidthPct.present ? cropWidthPct.value : this.cropWidthPct,
    sortOrder: sortOrder ?? this.sortOrder,
    isPrimary: isPrimary ?? this.isPrimary,
    captureLatitude: captureLatitude.present
        ? captureLatitude.value
        : this.captureLatitude,
    captureLongitude: captureLongitude.present
        ? captureLongitude.value
        : this.captureLongitude,
    captureAccuracyMeters: captureAccuracyMeters.present
        ? captureAccuracyMeters.value
        : this.captureAccuracyMeters,
    captureBearingDegrees: captureBearingDegrees.present
        ? captureBearingDegrees.value
        : this.captureBearingDegrees,
    layoutPinnedT: layoutPinnedT.present
        ? layoutPinnedT.value
        : this.layoutPinnedT,
  );
  Photo copyWithCompanion(PhotosCompanion data) {
    return Photo(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      kind: data.kind.present ? data.kind.value : this.kind,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      parentPhotoId: data.parentPhotoId.present
          ? data.parentPhotoId.value
          : this.parentPhotoId,
      cropXpct: data.cropXpct.present ? data.cropXpct.value : this.cropXpct,
      cropWidthPct: data.cropWidthPct.present
          ? data.cropWidthPct.value
          : this.cropWidthPct,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      isPrimary: data.isPrimary.present ? data.isPrimary.value : this.isPrimary,
      captureLatitude: data.captureLatitude.present
          ? data.captureLatitude.value
          : this.captureLatitude,
      captureLongitude: data.captureLongitude.present
          ? data.captureLongitude.value
          : this.captureLongitude,
      captureAccuracyMeters: data.captureAccuracyMeters.present
          ? data.captureAccuracyMeters.value
          : this.captureAccuracyMeters,
      captureBearingDegrees: data.captureBearingDegrees.present
          ? data.captureBearingDegrees.value
          : this.captureBearingDegrees,
      layoutPinnedT: data.layoutPinnedT.present
          ? data.layoutPinnedT.value
          : this.layoutPinnedT,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Photo(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('localPath: $localPath, ')
          ..write('kind: $kind, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('parentPhotoId: $parentPhotoId, ')
          ..write('cropXpct: $cropXpct, ')
          ..write('cropWidthPct: $cropWidthPct, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('isPrimary: $isPrimary, ')
          ..write('captureLatitude: $captureLatitude, ')
          ..write('captureLongitude: $captureLongitude, ')
          ..write('captureAccuracyMeters: $captureAccuracyMeters, ')
          ..write('captureBearingDegrees: $captureBearingDegrees, ')
          ..write('layoutPinnedT: $layoutPinnedT')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    localPath,
    kind,
    width,
    height,
    parentPhotoId,
    cropXpct,
    cropWidthPct,
    sortOrder,
    isPrimary,
    captureLatitude,
    captureLongitude,
    captureAccuracyMeters,
    captureBearingDegrees,
    layoutPinnedT,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Photo &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.wallId == this.wallId &&
          other.localPath == this.localPath &&
          other.kind == this.kind &&
          other.width == this.width &&
          other.height == this.height &&
          other.parentPhotoId == this.parentPhotoId &&
          other.cropXpct == this.cropXpct &&
          other.cropWidthPct == this.cropWidthPct &&
          other.sortOrder == this.sortOrder &&
          other.isPrimary == this.isPrimary &&
          other.captureLatitude == this.captureLatitude &&
          other.captureLongitude == this.captureLongitude &&
          other.captureAccuracyMeters == this.captureAccuracyMeters &&
          other.captureBearingDegrees == this.captureBearingDegrees &&
          other.layoutPinnedT == this.layoutPinnedT);
}

class PhotosCompanion extends UpdateCompanion<Photo> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String> wallId;
  final Value<String> localPath;
  final Value<String> kind;
  final Value<int> width;
  final Value<int> height;
  final Value<String?> parentPhotoId;
  final Value<double?> cropXpct;
  final Value<double?> cropWidthPct;
  final Value<int> sortOrder;
  final Value<bool> isPrimary;
  final Value<double?> captureLatitude;
  final Value<double?> captureLongitude;
  final Value<double?> captureAccuracyMeters;
  final Value<double?> captureBearingDegrees;
  final Value<double?> layoutPinnedT;
  final Value<int> rowid;
  const PhotosCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.localPath = const Value.absent(),
    this.kind = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.parentPhotoId = const Value.absent(),
    this.cropXpct = const Value.absent(),
    this.cropWidthPct = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.isPrimary = const Value.absent(),
    this.captureLatitude = const Value.absent(),
    this.captureLongitude = const Value.absent(),
    this.captureAccuracyMeters = const Value.absent(),
    this.captureBearingDegrees = const Value.absent(),
    this.layoutPinnedT = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PhotosCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    required String wallId,
    required String localPath,
    required String kind,
    required int width,
    required int height,
    this.parentPhotoId = const Value.absent(),
    this.cropXpct = const Value.absent(),
    this.cropWidthPct = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.isPrimary = const Value.absent(),
    this.captureLatitude = const Value.absent(),
    this.captureLongitude = const Value.absent(),
    this.captureAccuracyMeters = const Value.absent(),
    this.captureBearingDegrees = const Value.absent(),
    this.layoutPinnedT = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       wallId = Value(wallId),
       localPath = Value(localPath),
       kind = Value(kind),
       width = Value(width),
       height = Value(height);
  static Insertable<Photo> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? wallId,
    Expression<String>? localPath,
    Expression<String>? kind,
    Expression<int>? width,
    Expression<int>? height,
    Expression<String>? parentPhotoId,
    Expression<double>? cropXpct,
    Expression<double>? cropWidthPct,
    Expression<int>? sortOrder,
    Expression<bool>? isPrimary,
    Expression<double>? captureLatitude,
    Expression<double>? captureLongitude,
    Expression<double>? captureAccuracyMeters,
    Expression<double>? captureBearingDegrees,
    Expression<double>? layoutPinnedT,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (wallId != null) 'wall_id': wallId,
      if (localPath != null) 'local_path': localPath,
      if (kind != null) 'kind': kind,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (parentPhotoId != null) 'parent_photo_id': parentPhotoId,
      if (cropXpct != null) 'crop_xpct': cropXpct,
      if (cropWidthPct != null) 'crop_width_pct': cropWidthPct,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (isPrimary != null) 'is_primary': isPrimary,
      if (captureLatitude != null) 'capture_latitude': captureLatitude,
      if (captureLongitude != null) 'capture_longitude': captureLongitude,
      if (captureAccuracyMeters != null)
        'capture_accuracy_meters': captureAccuracyMeters,
      if (captureBearingDegrees != null)
        'capture_bearing_degrees': captureBearingDegrees,
      if (layoutPinnedT != null) 'layout_pinned_t': layoutPinnedT,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PhotosCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String>? wallId,
    Value<String>? localPath,
    Value<String>? kind,
    Value<int>? width,
    Value<int>? height,
    Value<String?>? parentPhotoId,
    Value<double?>? cropXpct,
    Value<double?>? cropWidthPct,
    Value<int>? sortOrder,
    Value<bool>? isPrimary,
    Value<double?>? captureLatitude,
    Value<double?>? captureLongitude,
    Value<double?>? captureAccuracyMeters,
    Value<double?>? captureBearingDegrees,
    Value<double?>? layoutPinnedT,
    Value<int>? rowid,
  }) {
    return PhotosCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      wallId: wallId ?? this.wallId,
      localPath: localPath ?? this.localPath,
      kind: kind ?? this.kind,
      width: width ?? this.width,
      height: height ?? this.height,
      parentPhotoId: parentPhotoId ?? this.parentPhotoId,
      cropXpct: cropXpct ?? this.cropXpct,
      cropWidthPct: cropWidthPct ?? this.cropWidthPct,
      sortOrder: sortOrder ?? this.sortOrder,
      isPrimary: isPrimary ?? this.isPrimary,
      captureLatitude: captureLatitude ?? this.captureLatitude,
      captureLongitude: captureLongitude ?? this.captureLongitude,
      captureAccuracyMeters:
          captureAccuracyMeters ?? this.captureAccuracyMeters,
      captureBearingDegrees:
          captureBearingDegrees ?? this.captureBearingDegrees,
      layoutPinnedT: layoutPinnedT ?? this.layoutPinnedT,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (parentPhotoId.present) {
      map['parent_photo_id'] = Variable<String>(parentPhotoId.value);
    }
    if (cropXpct.present) {
      map['crop_xpct'] = Variable<double>(cropXpct.value);
    }
    if (cropWidthPct.present) {
      map['crop_width_pct'] = Variable<double>(cropWidthPct.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (isPrimary.present) {
      map['is_primary'] = Variable<bool>(isPrimary.value);
    }
    if (captureLatitude.present) {
      map['capture_latitude'] = Variable<double>(captureLatitude.value);
    }
    if (captureLongitude.present) {
      map['capture_longitude'] = Variable<double>(captureLongitude.value);
    }
    if (captureAccuracyMeters.present) {
      map['capture_accuracy_meters'] = Variable<double>(
        captureAccuracyMeters.value,
      );
    }
    if (captureBearingDegrees.present) {
      map['capture_bearing_degrees'] = Variable<double>(
        captureBearingDegrees.value,
      );
    }
    if (layoutPinnedT.present) {
      map['layout_pinned_t'] = Variable<double>(layoutPinnedT.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PhotosCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('localPath: $localPath, ')
          ..write('kind: $kind, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('parentPhotoId: $parentPhotoId, ')
          ..write('cropXpct: $cropXpct, ')
          ..write('cropWidthPct: $cropWidthPct, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('isPrimary: $isPrimary, ')
          ..write('captureLatitude: $captureLatitude, ')
          ..write('captureLongitude: $captureLongitude, ')
          ..write('captureAccuracyMeters: $captureAccuracyMeters, ')
          ..write('captureBearingDegrees: $captureBearingDegrees, ')
          ..write('layoutPinnedT: $layoutPinnedT, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RoutesTable extends Routes with TableInfo<$RoutesTable, Route> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RoutesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES walls (id)',
    ),
  );
  static const VerificationMeta _photoIdMeta = const VerificationMeta(
    'photoId',
  );
  @override
  late final GeneratedColumn<String> photoId = GeneratedColumn<String>(
    'photo_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES photos (id)',
    ),
  );
  static const VerificationMeta _numberMeta = const VerificationMeta('number');
  @override
  late final GeneratedColumn<int> number = GeneratedColumn<int>(
    'number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _gradeSystemMeta = const VerificationMeta(
    'gradeSystem',
  );
  @override
  late final GeneratedColumn<String> gradeSystem = GeneratedColumn<String>(
    'grade_system',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _gradeRawMeta = const VerificationMeta(
    'gradeRaw',
  );
  @override
  late final GeneratedColumn<String> gradeRaw = GeneratedColumn<String>(
    'grade_raw',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _gradeSortKeyMeta = const VerificationMeta(
    'gradeSortKey',
  );
  @override
  late final GeneratedColumn<double> gradeSortKey = GeneratedColumn<double>(
    'grade_sort_key',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _styleMeta = const VerificationMeta('style');
  @override
  late final GeneratedColumn<String> style = GeneratedColumn<String>(
    'style',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _colorIndexMeta = const VerificationMeta(
    'colorIndex',
  );
  @override
  late final GeneratedColumn<int> colorIndex = GeneratedColumn<int>(
    'color_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pointsJsonMeta = const VerificationMeta(
    'pointsJson',
  );
  @override
  late final GeneratedColumn<String> pointsJson = GeneratedColumn<String>(
    'points_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _symbolsJsonMeta = const VerificationMeta(
    'symbolsJson',
  );
  @override
  late final GeneratedColumn<String> symbolsJson = GeneratedColumn<String>(
    'symbols_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _visibleMeta = const VerificationMeta(
    'visible',
  );
  @override
  late final GeneratedColumn<bool> visible = GeneratedColumn<bool>(
    'visible',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("visible" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _betaVideoUrlMeta = const VerificationMeta(
    'betaVideoUrl',
  );
  @override
  late final GeneratedColumn<String> betaVideoUrl = GeneratedColumn<String>(
    'beta_video_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _styleTagsJsonMeta = const VerificationMeta(
    'styleTagsJson',
  );
  @override
  late final GeneratedColumn<String> styleTagsJson = GeneratedColumn<String>(
    'style_tags_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _starsMeta = const VerificationMeta('stars');
  @override
  late final GeneratedColumn<int> stars = GeneratedColumn<int>(
    'stars',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    photoId,
    number,
    name,
    gradeSystem,
    gradeRaw,
    gradeSortKey,
    style,
    description,
    colorIndex,
    pointsJson,
    symbolsJson,
    sortOrder,
    visible,
    betaVideoUrl,
    styleTagsJson,
    stars,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'routes';
  @override
  VerificationContext validateIntegrity(
    Insertable<Route> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    } else if (isInserting) {
      context.missing(_wallIdMeta);
    }
    if (data.containsKey('photo_id')) {
      context.handle(
        _photoIdMeta,
        photoId.isAcceptableOrUnknown(data['photo_id']!, _photoIdMeta),
      );
    } else if (isInserting) {
      context.missing(_photoIdMeta);
    }
    if (data.containsKey('number')) {
      context.handle(
        _numberMeta,
        number.isAcceptableOrUnknown(data['number']!, _numberMeta),
      );
    } else if (isInserting) {
      context.missing(_numberMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('grade_system')) {
      context.handle(
        _gradeSystemMeta,
        gradeSystem.isAcceptableOrUnknown(
          data['grade_system']!,
          _gradeSystemMeta,
        ),
      );
    }
    if (data.containsKey('grade_raw')) {
      context.handle(
        _gradeRawMeta,
        gradeRaw.isAcceptableOrUnknown(data['grade_raw']!, _gradeRawMeta),
      );
    }
    if (data.containsKey('grade_sort_key')) {
      context.handle(
        _gradeSortKeyMeta,
        gradeSortKey.isAcceptableOrUnknown(
          data['grade_sort_key']!,
          _gradeSortKeyMeta,
        ),
      );
    }
    if (data.containsKey('style')) {
      context.handle(
        _styleMeta,
        style.isAcceptableOrUnknown(data['style']!, _styleMeta),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('color_index')) {
      context.handle(
        _colorIndexMeta,
        colorIndex.isAcceptableOrUnknown(data['color_index']!, _colorIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_colorIndexMeta);
    }
    if (data.containsKey('points_json')) {
      context.handle(
        _pointsJsonMeta,
        pointsJson.isAcceptableOrUnknown(data['points_json']!, _pointsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_pointsJsonMeta);
    }
    if (data.containsKey('symbols_json')) {
      context.handle(
        _symbolsJsonMeta,
        symbolsJson.isAcceptableOrUnknown(
          data['symbols_json']!,
          _symbolsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_symbolsJsonMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    if (data.containsKey('visible')) {
      context.handle(
        _visibleMeta,
        visible.isAcceptableOrUnknown(data['visible']!, _visibleMeta),
      );
    }
    if (data.containsKey('beta_video_url')) {
      context.handle(
        _betaVideoUrlMeta,
        betaVideoUrl.isAcceptableOrUnknown(
          data['beta_video_url']!,
          _betaVideoUrlMeta,
        ),
      );
    }
    if (data.containsKey('style_tags_json')) {
      context.handle(
        _styleTagsJsonMeta,
        styleTagsJson.isAcceptableOrUnknown(
          data['style_tags_json']!,
          _styleTagsJsonMeta,
        ),
      );
    }
    if (data.containsKey('stars')) {
      context.handle(
        _starsMeta,
        stars.isAcceptableOrUnknown(data['stars']!, _starsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Route map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Route(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      )!,
      photoId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}photo_id'],
      )!,
      number: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}number'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      ),
      gradeSystem: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grade_system'],
      ),
      gradeRaw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grade_raw'],
      ),
      gradeSortKey: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}grade_sort_key'],
      ),
      style: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}style'],
      ),
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      colorIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_index'],
      )!,
      pointsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}points_json'],
      )!,
      symbolsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}symbols_json'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      visible: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}visible'],
      )!,
      betaVideoUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}beta_video_url'],
      ),
      styleTagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}style_tags_json'],
      ),
      stars: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stars'],
      ),
    );
  }

  @override
  $RoutesTable createAlias(String alias) {
    return $RoutesTable(attachedDatabase, alias);
  }
}

class Route extends DataClass implements Insertable<Route> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;
  final String wallId;
  final String photoId;
  final int number;
  final String? name;
  final String? gradeSystem;
  final String? gradeRaw;
  final double? gradeSortKey;
  final String? style;
  final String? description;
  final int colorIndex;
  final String pointsJson;
  final String symbolsJson;
  final int sortOrder;
  final bool visible;

  /// External beta-video URL (e.g. a YouTube/Instagram link) for this
  /// route. Free-form, validated only client-side (see
  /// `RouteMetadataSheet`) — `null` if unset.
  final String? betaVideoUrl;

  /// This route's style tags, encoded as a JSON array of strings via
  /// `core/routes/route_styles.dart`'s `encodeStyleTags`/`decodeStyleTags`
  /// (curated tags + arbitrary custom ones). `null` (rather than `'[]'`)
  /// when the route has no tags — `RouteRepository.upsertRoute` writes
  /// `null` for an empty tag list rather than the encoded empty array, so
  /// this column stays `null` for every route that predates this feature.
  final String? styleTagsJson;

  /// 0-3 star quality rating. `null` means unrated (distinct from `0`,
  /// which is an explicit "0 stars" rating).
  final int? stars;
  const Route({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    required this.wallId,
    required this.photoId,
    required this.number,
    this.name,
    this.gradeSystem,
    this.gradeRaw,
    this.gradeSortKey,
    this.style,
    this.description,
    required this.colorIndex,
    required this.pointsJson,
    required this.symbolsJson,
    required this.sortOrder,
    required this.visible,
    this.betaVideoUrl,
    this.styleTagsJson,
    this.stars,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    map['wall_id'] = Variable<String>(wallId);
    map['photo_id'] = Variable<String>(photoId);
    map['number'] = Variable<int>(number);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    if (!nullToAbsent || gradeSystem != null) {
      map['grade_system'] = Variable<String>(gradeSystem);
    }
    if (!nullToAbsent || gradeRaw != null) {
      map['grade_raw'] = Variable<String>(gradeRaw);
    }
    if (!nullToAbsent || gradeSortKey != null) {
      map['grade_sort_key'] = Variable<double>(gradeSortKey);
    }
    if (!nullToAbsent || style != null) {
      map['style'] = Variable<String>(style);
    }
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    map['color_index'] = Variable<int>(colorIndex);
    map['points_json'] = Variable<String>(pointsJson);
    map['symbols_json'] = Variable<String>(symbolsJson);
    map['sort_order'] = Variable<int>(sortOrder);
    map['visible'] = Variable<bool>(visible);
    if (!nullToAbsent || betaVideoUrl != null) {
      map['beta_video_url'] = Variable<String>(betaVideoUrl);
    }
    if (!nullToAbsent || styleTagsJson != null) {
      map['style_tags_json'] = Variable<String>(styleTagsJson);
    }
    if (!nullToAbsent || stars != null) {
      map['stars'] = Variable<int>(stars);
    }
    return map;
  }

  RoutesCompanion toCompanion(bool nullToAbsent) {
    return RoutesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      wallId: Value(wallId),
      photoId: Value(photoId),
      number: Value(number),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      gradeSystem: gradeSystem == null && nullToAbsent
          ? const Value.absent()
          : Value(gradeSystem),
      gradeRaw: gradeRaw == null && nullToAbsent
          ? const Value.absent()
          : Value(gradeRaw),
      gradeSortKey: gradeSortKey == null && nullToAbsent
          ? const Value.absent()
          : Value(gradeSortKey),
      style: style == null && nullToAbsent
          ? const Value.absent()
          : Value(style),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      colorIndex: Value(colorIndex),
      pointsJson: Value(pointsJson),
      symbolsJson: Value(symbolsJson),
      sortOrder: Value(sortOrder),
      visible: Value(visible),
      betaVideoUrl: betaVideoUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(betaVideoUrl),
      styleTagsJson: styleTagsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(styleTagsJson),
      stars: stars == null && nullToAbsent
          ? const Value.absent()
          : Value(stars),
    );
  }

  factory Route.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Route(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      wallId: serializer.fromJson<String>(json['wallId']),
      photoId: serializer.fromJson<String>(json['photoId']),
      number: serializer.fromJson<int>(json['number']),
      name: serializer.fromJson<String?>(json['name']),
      gradeSystem: serializer.fromJson<String?>(json['gradeSystem']),
      gradeRaw: serializer.fromJson<String?>(json['gradeRaw']),
      gradeSortKey: serializer.fromJson<double?>(json['gradeSortKey']),
      style: serializer.fromJson<String?>(json['style']),
      description: serializer.fromJson<String?>(json['description']),
      colorIndex: serializer.fromJson<int>(json['colorIndex']),
      pointsJson: serializer.fromJson<String>(json['pointsJson']),
      symbolsJson: serializer.fromJson<String>(json['symbolsJson']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      visible: serializer.fromJson<bool>(json['visible']),
      betaVideoUrl: serializer.fromJson<String?>(json['betaVideoUrl']),
      styleTagsJson: serializer.fromJson<String?>(json['styleTagsJson']),
      stars: serializer.fromJson<int?>(json['stars']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'wallId': serializer.toJson<String>(wallId),
      'photoId': serializer.toJson<String>(photoId),
      'number': serializer.toJson<int>(number),
      'name': serializer.toJson<String?>(name),
      'gradeSystem': serializer.toJson<String?>(gradeSystem),
      'gradeRaw': serializer.toJson<String?>(gradeRaw),
      'gradeSortKey': serializer.toJson<double?>(gradeSortKey),
      'style': serializer.toJson<String?>(style),
      'description': serializer.toJson<String?>(description),
      'colorIndex': serializer.toJson<int>(colorIndex),
      'pointsJson': serializer.toJson<String>(pointsJson),
      'symbolsJson': serializer.toJson<String>(symbolsJson),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'visible': serializer.toJson<bool>(visible),
      'betaVideoUrl': serializer.toJson<String?>(betaVideoUrl),
      'styleTagsJson': serializer.toJson<String?>(styleTagsJson),
      'stars': serializer.toJson<int?>(stars),
    };
  }

  Route copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    String? wallId,
    String? photoId,
    int? number,
    Value<String?> name = const Value.absent(),
    Value<String?> gradeSystem = const Value.absent(),
    Value<String?> gradeRaw = const Value.absent(),
    Value<double?> gradeSortKey = const Value.absent(),
    Value<String?> style = const Value.absent(),
    Value<String?> description = const Value.absent(),
    int? colorIndex,
    String? pointsJson,
    String? symbolsJson,
    int? sortOrder,
    bool? visible,
    Value<String?> betaVideoUrl = const Value.absent(),
    Value<String?> styleTagsJson = const Value.absent(),
    Value<int?> stars = const Value.absent(),
  }) => Route(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    wallId: wallId ?? this.wallId,
    photoId: photoId ?? this.photoId,
    number: number ?? this.number,
    name: name.present ? name.value : this.name,
    gradeSystem: gradeSystem.present ? gradeSystem.value : this.gradeSystem,
    gradeRaw: gradeRaw.present ? gradeRaw.value : this.gradeRaw,
    gradeSortKey: gradeSortKey.present ? gradeSortKey.value : this.gradeSortKey,
    style: style.present ? style.value : this.style,
    description: description.present ? description.value : this.description,
    colorIndex: colorIndex ?? this.colorIndex,
    pointsJson: pointsJson ?? this.pointsJson,
    symbolsJson: symbolsJson ?? this.symbolsJson,
    sortOrder: sortOrder ?? this.sortOrder,
    visible: visible ?? this.visible,
    betaVideoUrl: betaVideoUrl.present ? betaVideoUrl.value : this.betaVideoUrl,
    styleTagsJson: styleTagsJson.present
        ? styleTagsJson.value
        : this.styleTagsJson,
    stars: stars.present ? stars.value : this.stars,
  );
  Route copyWithCompanion(RoutesCompanion data) {
    return Route(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      photoId: data.photoId.present ? data.photoId.value : this.photoId,
      number: data.number.present ? data.number.value : this.number,
      name: data.name.present ? data.name.value : this.name,
      gradeSystem: data.gradeSystem.present
          ? data.gradeSystem.value
          : this.gradeSystem,
      gradeRaw: data.gradeRaw.present ? data.gradeRaw.value : this.gradeRaw,
      gradeSortKey: data.gradeSortKey.present
          ? data.gradeSortKey.value
          : this.gradeSortKey,
      style: data.style.present ? data.style.value : this.style,
      description: data.description.present
          ? data.description.value
          : this.description,
      colorIndex: data.colorIndex.present
          ? data.colorIndex.value
          : this.colorIndex,
      pointsJson: data.pointsJson.present
          ? data.pointsJson.value
          : this.pointsJson,
      symbolsJson: data.symbolsJson.present
          ? data.symbolsJson.value
          : this.symbolsJson,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      visible: data.visible.present ? data.visible.value : this.visible,
      betaVideoUrl: data.betaVideoUrl.present
          ? data.betaVideoUrl.value
          : this.betaVideoUrl,
      styleTagsJson: data.styleTagsJson.present
          ? data.styleTagsJson.value
          : this.styleTagsJson,
      stars: data.stars.present ? data.stars.value : this.stars,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Route(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('photoId: $photoId, ')
          ..write('number: $number, ')
          ..write('name: $name, ')
          ..write('gradeSystem: $gradeSystem, ')
          ..write('gradeRaw: $gradeRaw, ')
          ..write('gradeSortKey: $gradeSortKey, ')
          ..write('style: $style, ')
          ..write('description: $description, ')
          ..write('colorIndex: $colorIndex, ')
          ..write('pointsJson: $pointsJson, ')
          ..write('symbolsJson: $symbolsJson, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('visible: $visible, ')
          ..write('betaVideoUrl: $betaVideoUrl, ')
          ..write('styleTagsJson: $styleTagsJson, ')
          ..write('stars: $stars')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    photoId,
    number,
    name,
    gradeSystem,
    gradeRaw,
    gradeSortKey,
    style,
    description,
    colorIndex,
    pointsJson,
    symbolsJson,
    sortOrder,
    visible,
    betaVideoUrl,
    styleTagsJson,
    stars,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Route &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.wallId == this.wallId &&
          other.photoId == this.photoId &&
          other.number == this.number &&
          other.name == this.name &&
          other.gradeSystem == this.gradeSystem &&
          other.gradeRaw == this.gradeRaw &&
          other.gradeSortKey == this.gradeSortKey &&
          other.style == this.style &&
          other.description == this.description &&
          other.colorIndex == this.colorIndex &&
          other.pointsJson == this.pointsJson &&
          other.symbolsJson == this.symbolsJson &&
          other.sortOrder == this.sortOrder &&
          other.visible == this.visible &&
          other.betaVideoUrl == this.betaVideoUrl &&
          other.styleTagsJson == this.styleTagsJson &&
          other.stars == this.stars);
}

class RoutesCompanion extends UpdateCompanion<Route> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String> wallId;
  final Value<String> photoId;
  final Value<int> number;
  final Value<String?> name;
  final Value<String?> gradeSystem;
  final Value<String?> gradeRaw;
  final Value<double?> gradeSortKey;
  final Value<String?> style;
  final Value<String?> description;
  final Value<int> colorIndex;
  final Value<String> pointsJson;
  final Value<String> symbolsJson;
  final Value<int> sortOrder;
  final Value<bool> visible;
  final Value<String?> betaVideoUrl;
  final Value<String?> styleTagsJson;
  final Value<int?> stars;
  final Value<int> rowid;
  const RoutesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.photoId = const Value.absent(),
    this.number = const Value.absent(),
    this.name = const Value.absent(),
    this.gradeSystem = const Value.absent(),
    this.gradeRaw = const Value.absent(),
    this.gradeSortKey = const Value.absent(),
    this.style = const Value.absent(),
    this.description = const Value.absent(),
    this.colorIndex = const Value.absent(),
    this.pointsJson = const Value.absent(),
    this.symbolsJson = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.visible = const Value.absent(),
    this.betaVideoUrl = const Value.absent(),
    this.styleTagsJson = const Value.absent(),
    this.stars = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RoutesCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    required String wallId,
    required String photoId,
    required int number,
    this.name = const Value.absent(),
    this.gradeSystem = const Value.absent(),
    this.gradeRaw = const Value.absent(),
    this.gradeSortKey = const Value.absent(),
    this.style = const Value.absent(),
    this.description = const Value.absent(),
    required int colorIndex,
    required String pointsJson,
    required String symbolsJson,
    required int sortOrder,
    this.visible = const Value.absent(),
    this.betaVideoUrl = const Value.absent(),
    this.styleTagsJson = const Value.absent(),
    this.stars = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       wallId = Value(wallId),
       photoId = Value(photoId),
       number = Value(number),
       colorIndex = Value(colorIndex),
       pointsJson = Value(pointsJson),
       symbolsJson = Value(symbolsJson),
       sortOrder = Value(sortOrder);
  static Insertable<Route> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? wallId,
    Expression<String>? photoId,
    Expression<int>? number,
    Expression<String>? name,
    Expression<String>? gradeSystem,
    Expression<String>? gradeRaw,
    Expression<double>? gradeSortKey,
    Expression<String>? style,
    Expression<String>? description,
    Expression<int>? colorIndex,
    Expression<String>? pointsJson,
    Expression<String>? symbolsJson,
    Expression<int>? sortOrder,
    Expression<bool>? visible,
    Expression<String>? betaVideoUrl,
    Expression<String>? styleTagsJson,
    Expression<int>? stars,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (wallId != null) 'wall_id': wallId,
      if (photoId != null) 'photo_id': photoId,
      if (number != null) 'number': number,
      if (name != null) 'name': name,
      if (gradeSystem != null) 'grade_system': gradeSystem,
      if (gradeRaw != null) 'grade_raw': gradeRaw,
      if (gradeSortKey != null) 'grade_sort_key': gradeSortKey,
      if (style != null) 'style': style,
      if (description != null) 'description': description,
      if (colorIndex != null) 'color_index': colorIndex,
      if (pointsJson != null) 'points_json': pointsJson,
      if (symbolsJson != null) 'symbols_json': symbolsJson,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (visible != null) 'visible': visible,
      if (betaVideoUrl != null) 'beta_video_url': betaVideoUrl,
      if (styleTagsJson != null) 'style_tags_json': styleTagsJson,
      if (stars != null) 'stars': stars,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RoutesCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String>? wallId,
    Value<String>? photoId,
    Value<int>? number,
    Value<String?>? name,
    Value<String?>? gradeSystem,
    Value<String?>? gradeRaw,
    Value<double?>? gradeSortKey,
    Value<String?>? style,
    Value<String?>? description,
    Value<int>? colorIndex,
    Value<String>? pointsJson,
    Value<String>? symbolsJson,
    Value<int>? sortOrder,
    Value<bool>? visible,
    Value<String?>? betaVideoUrl,
    Value<String?>? styleTagsJson,
    Value<int?>? stars,
    Value<int>? rowid,
  }) {
    return RoutesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      wallId: wallId ?? this.wallId,
      photoId: photoId ?? this.photoId,
      number: number ?? this.number,
      name: name ?? this.name,
      gradeSystem: gradeSystem ?? this.gradeSystem,
      gradeRaw: gradeRaw ?? this.gradeRaw,
      gradeSortKey: gradeSortKey ?? this.gradeSortKey,
      style: style ?? this.style,
      description: description ?? this.description,
      colorIndex: colorIndex ?? this.colorIndex,
      pointsJson: pointsJson ?? this.pointsJson,
      symbolsJson: symbolsJson ?? this.symbolsJson,
      sortOrder: sortOrder ?? this.sortOrder,
      visible: visible ?? this.visible,
      betaVideoUrl: betaVideoUrl ?? this.betaVideoUrl,
      styleTagsJson: styleTagsJson ?? this.styleTagsJson,
      stars: stars ?? this.stars,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (photoId.present) {
      map['photo_id'] = Variable<String>(photoId.value);
    }
    if (number.present) {
      map['number'] = Variable<int>(number.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (gradeSystem.present) {
      map['grade_system'] = Variable<String>(gradeSystem.value);
    }
    if (gradeRaw.present) {
      map['grade_raw'] = Variable<String>(gradeRaw.value);
    }
    if (gradeSortKey.present) {
      map['grade_sort_key'] = Variable<double>(gradeSortKey.value);
    }
    if (style.present) {
      map['style'] = Variable<String>(style.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (colorIndex.present) {
      map['color_index'] = Variable<int>(colorIndex.value);
    }
    if (pointsJson.present) {
      map['points_json'] = Variable<String>(pointsJson.value);
    }
    if (symbolsJson.present) {
      map['symbols_json'] = Variable<String>(symbolsJson.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (visible.present) {
      map['visible'] = Variable<bool>(visible.value);
    }
    if (betaVideoUrl.present) {
      map['beta_video_url'] = Variable<String>(betaVideoUrl.value);
    }
    if (styleTagsJson.present) {
      map['style_tags_json'] = Variable<String>(styleTagsJson.value);
    }
    if (stars.present) {
      map['stars'] = Variable<int>(stars.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RoutesCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('photoId: $photoId, ')
          ..write('number: $number, ')
          ..write('name: $name, ')
          ..write('gradeSystem: $gradeSystem, ')
          ..write('gradeRaw: $gradeRaw, ')
          ..write('gradeSortKey: $gradeSortKey, ')
          ..write('style: $style, ')
          ..write('description: $description, ')
          ..write('colorIndex: $colorIndex, ')
          ..write('pointsJson: $pointsJson, ')
          ..write('symbolsJson: $symbolsJson, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('visible: $visible, ')
          ..write('betaVideoUrl: $betaVideoUrl, ')
          ..write('styleTagsJson: $styleTagsJson, ')
          ..write('stars: $stars, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RouteLinesTable extends RouteLines
    with TableInfo<$RouteLinesTable, RouteLine> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RouteLinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _routeIdMeta = const VerificationMeta(
    'routeId',
  );
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
    'route_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES routes (id)',
    ),
  );
  static const VerificationMeta _photoIdMeta = const VerificationMeta(
    'photoId',
  );
  @override
  late final GeneratedColumn<String> photoId = GeneratedColumn<String>(
    'photo_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES photos (id)',
    ),
  );
  static const VerificationMeta _pointsJsonMeta = const VerificationMeta(
    'pointsJson',
  );
  @override
  late final GeneratedColumn<String> pointsJson = GeneratedColumn<String>(
    'points_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _symbolsJsonMeta = const VerificationMeta(
    'symbolsJson',
  );
  @override
  late final GeneratedColumn<String> symbolsJson = GeneratedColumn<String>(
    'symbols_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    routeId,
    photoId,
    pointsJson,
    symbolsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'route_lines';
  @override
  VerificationContext validateIntegrity(
    Insertable<RouteLine> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('route_id')) {
      context.handle(
        _routeIdMeta,
        routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_routeIdMeta);
    }
    if (data.containsKey('photo_id')) {
      context.handle(
        _photoIdMeta,
        photoId.isAcceptableOrUnknown(data['photo_id']!, _photoIdMeta),
      );
    } else if (isInserting) {
      context.missing(_photoIdMeta);
    }
    if (data.containsKey('points_json')) {
      context.handle(
        _pointsJsonMeta,
        pointsJson.isAcceptableOrUnknown(data['points_json']!, _pointsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_pointsJsonMeta);
    }
    if (data.containsKey('symbols_json')) {
      context.handle(
        _symbolsJsonMeta,
        symbolsJson.isAcceptableOrUnknown(
          data['symbols_json']!,
          _symbolsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_symbolsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RouteLine map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RouteLine(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      routeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_id'],
      )!,
      photoId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}photo_id'],
      )!,
      pointsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}points_json'],
      )!,
      symbolsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}symbols_json'],
      )!,
    );
  }

  @override
  $RouteLinesTable createAlias(String alias) {
    return $RouteLinesTable(attachedDatabase, alias);
  }
}

class RouteLine extends DataClass implements Insertable<RouteLine> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;

  /// The climb this line depicts. Every piece of shared data — name, grade,
  /// stars, tags, ascents — is read through here, which is what makes two
  /// drawings of one climb genuinely one climb.
  final String routeId;

  /// The photo this line is drawn on. Never the route's home photo: that
  /// line lives on the [Routes] row itself, and the partial unique index
  /// above stops a duplicate landing here for it.
  final String photoId;

  /// Normalised points, in the same encoding [Routes.pointsJson] uses, so
  /// both kinds of line render through one painter with no branch.
  final String pointsJson;
  final String symbolsJson;
  const RouteLine({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    required this.routeId,
    required this.photoId,
    required this.pointsJson,
    required this.symbolsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    map['route_id'] = Variable<String>(routeId);
    map['photo_id'] = Variable<String>(photoId);
    map['points_json'] = Variable<String>(pointsJson);
    map['symbols_json'] = Variable<String>(symbolsJson);
    return map;
  }

  RouteLinesCompanion toCompanion(bool nullToAbsent) {
    return RouteLinesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      routeId: Value(routeId),
      photoId: Value(photoId),
      pointsJson: Value(pointsJson),
      symbolsJson: Value(symbolsJson),
    );
  }

  factory RouteLine.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RouteLine(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      routeId: serializer.fromJson<String>(json['routeId']),
      photoId: serializer.fromJson<String>(json['photoId']),
      pointsJson: serializer.fromJson<String>(json['pointsJson']),
      symbolsJson: serializer.fromJson<String>(json['symbolsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'routeId': serializer.toJson<String>(routeId),
      'photoId': serializer.toJson<String>(photoId),
      'pointsJson': serializer.toJson<String>(pointsJson),
      'symbolsJson': serializer.toJson<String>(symbolsJson),
    };
  }

  RouteLine copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    String? routeId,
    String? photoId,
    String? pointsJson,
    String? symbolsJson,
  }) => RouteLine(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    routeId: routeId ?? this.routeId,
    photoId: photoId ?? this.photoId,
    pointsJson: pointsJson ?? this.pointsJson,
    symbolsJson: symbolsJson ?? this.symbolsJson,
  );
  RouteLine copyWithCompanion(RouteLinesCompanion data) {
    return RouteLine(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      photoId: data.photoId.present ? data.photoId.value : this.photoId,
      pointsJson: data.pointsJson.present
          ? data.pointsJson.value
          : this.pointsJson,
      symbolsJson: data.symbolsJson.present
          ? data.symbolsJson.value
          : this.symbolsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RouteLine(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('routeId: $routeId, ')
          ..write('photoId: $photoId, ')
          ..write('pointsJson: $pointsJson, ')
          ..write('symbolsJson: $symbolsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    routeId,
    photoId,
    pointsJson,
    symbolsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RouteLine &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.routeId == this.routeId &&
          other.photoId == this.photoId &&
          other.pointsJson == this.pointsJson &&
          other.symbolsJson == this.symbolsJson);
}

class RouteLinesCompanion extends UpdateCompanion<RouteLine> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String> routeId;
  final Value<String> photoId;
  final Value<String> pointsJson;
  final Value<String> symbolsJson;
  final Value<int> rowid;
  const RouteLinesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.routeId = const Value.absent(),
    this.photoId = const Value.absent(),
    this.pointsJson = const Value.absent(),
    this.symbolsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RouteLinesCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    required String routeId,
    required String photoId,
    required String pointsJson,
    required String symbolsJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       routeId = Value(routeId),
       photoId = Value(photoId),
       pointsJson = Value(pointsJson),
       symbolsJson = Value(symbolsJson);
  static Insertable<RouteLine> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? routeId,
    Expression<String>? photoId,
    Expression<String>? pointsJson,
    Expression<String>? symbolsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (routeId != null) 'route_id': routeId,
      if (photoId != null) 'photo_id': photoId,
      if (pointsJson != null) 'points_json': pointsJson,
      if (symbolsJson != null) 'symbols_json': symbolsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RouteLinesCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String>? routeId,
    Value<String>? photoId,
    Value<String>? pointsJson,
    Value<String>? symbolsJson,
    Value<int>? rowid,
  }) {
    return RouteLinesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      routeId: routeId ?? this.routeId,
      photoId: photoId ?? this.photoId,
      pointsJson: pointsJson ?? this.pointsJson,
      symbolsJson: symbolsJson ?? this.symbolsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (photoId.present) {
      map['photo_id'] = Variable<String>(photoId.value);
    }
    if (pointsJson.present) {
      map['points_json'] = Variable<String>(pointsJson.value);
    }
    if (symbolsJson.present) {
      map['symbols_json'] = Variable<String>(symbolsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RouteLinesCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('routeId: $routeId, ')
          ..write('photoId: $photoId, ')
          ..write('pointsJson: $pointsJson, ')
          ..write('symbolsJson: $symbolsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AscentsTable extends Ascents with TableInfo<$AscentsTable, Ascent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AscentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _routeIdMeta = const VerificationMeta(
    'routeId',
  );
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
    'route_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES routes (id)',
    ),
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES walls (id)',
    ),
  );
  static const VerificationMeta _climbedAtMeta = const VerificationMeta(
    'climbedAt',
  );
  @override
  late final GeneratedColumn<int> climbedAt = GeneratedColumn<int>(
    'climbed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _styleMeta = const VerificationMeta('style');
  @override
  late final GeneratedColumn<String> style = GeneratedColumn<String>(
    'style',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _gradeOpinionMeta = const VerificationMeta(
    'gradeOpinion',
  );
  @override
  late final GeneratedColumn<String> gradeOpinion = GeneratedColumn<String>(
    'grade_opinion',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _visibilityMeta = const VerificationMeta(
    'visibility',
  );
  @override
  late final GeneratedColumn<String> visibility = GeneratedColumn<String>(
    'visibility',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('private'),
  );
  static const VerificationMeta _authorNameMeta = const VerificationMeta(
    'authorName',
  );
  @override
  late final GeneratedColumn<String> authorName = GeneratedColumn<String>(
    'author_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    routeId,
    wallId,
    climbedAt,
    style,
    notes,
    gradeOpinion,
    visibility,
    authorName,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ascents';
  @override
  VerificationContext validateIntegrity(
    Insertable<Ascent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('route_id')) {
      context.handle(
        _routeIdMeta,
        routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_routeIdMeta);
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    } else if (isInserting) {
      context.missing(_wallIdMeta);
    }
    if (data.containsKey('climbed_at')) {
      context.handle(
        _climbedAtMeta,
        climbedAt.isAcceptableOrUnknown(data['climbed_at']!, _climbedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_climbedAtMeta);
    }
    if (data.containsKey('style')) {
      context.handle(
        _styleMeta,
        style.isAcceptableOrUnknown(data['style']!, _styleMeta),
      );
    } else if (isInserting) {
      context.missing(_styleMeta);
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('grade_opinion')) {
      context.handle(
        _gradeOpinionMeta,
        gradeOpinion.isAcceptableOrUnknown(
          data['grade_opinion']!,
          _gradeOpinionMeta,
        ),
      );
    }
    if (data.containsKey('visibility')) {
      context.handle(
        _visibilityMeta,
        visibility.isAcceptableOrUnknown(data['visibility']!, _visibilityMeta),
      );
    }
    if (data.containsKey('author_name')) {
      context.handle(
        _authorNameMeta,
        authorName.isAcceptableOrUnknown(data['author_name']!, _authorNameMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Ascent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Ascent(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      routeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_id'],
      )!,
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      )!,
      climbedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}climbed_at'],
      )!,
      style: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}style'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      gradeOpinion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grade_opinion'],
      ),
      visibility: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}visibility'],
      )!,
      authorName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_name'],
      ),
    );
  }

  @override
  $AscentsTable createAlias(String alias) {
    return $AscentsTable(attachedDatabase, alias);
  }
}

class Ascent extends DataClass implements Insertable<Ascent> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;
  final String routeId;
  final String wallId;
  final int climbedAt;
  final String style;
  final String? notes;
  final String? gradeOpinion;

  /// Cloud-sharing visibility for this logged ascent, added by Feature #12
  /// (public opt-in ascent logs): `'private'` (default; owner-only, the
  /// original ascent-logbook behavior) or `'shared'` (visible on the
  /// Community ascent feed). Same shape as [Walls.visibility] — app
  /// enforces the two values, no DB CHECK constraint.
  final String visibility;

  /// Optional display name of the ascent's author, shown alongside a
  /// `'shared'` ascent on the Community feed. Mirrors
  /// [Comments.authorName]'s shape/purpose. `null` for every pre-Feature-#12
  /// ascent and for any private one that never sets it.
  final String? authorName;
  const Ascent({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    required this.routeId,
    required this.wallId,
    required this.climbedAt,
    required this.style,
    this.notes,
    this.gradeOpinion,
    required this.visibility,
    this.authorName,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    map['route_id'] = Variable<String>(routeId);
    map['wall_id'] = Variable<String>(wallId);
    map['climbed_at'] = Variable<int>(climbedAt);
    map['style'] = Variable<String>(style);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || gradeOpinion != null) {
      map['grade_opinion'] = Variable<String>(gradeOpinion);
    }
    map['visibility'] = Variable<String>(visibility);
    if (!nullToAbsent || authorName != null) {
      map['author_name'] = Variable<String>(authorName);
    }
    return map;
  }

  AscentsCompanion toCompanion(bool nullToAbsent) {
    return AscentsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      routeId: Value(routeId),
      wallId: Value(wallId),
      climbedAt: Value(climbedAt),
      style: Value(style),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      gradeOpinion: gradeOpinion == null && nullToAbsent
          ? const Value.absent()
          : Value(gradeOpinion),
      visibility: Value(visibility),
      authorName: authorName == null && nullToAbsent
          ? const Value.absent()
          : Value(authorName),
    );
  }

  factory Ascent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Ascent(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      routeId: serializer.fromJson<String>(json['routeId']),
      wallId: serializer.fromJson<String>(json['wallId']),
      climbedAt: serializer.fromJson<int>(json['climbedAt']),
      style: serializer.fromJson<String>(json['style']),
      notes: serializer.fromJson<String?>(json['notes']),
      gradeOpinion: serializer.fromJson<String?>(json['gradeOpinion']),
      visibility: serializer.fromJson<String>(json['visibility']),
      authorName: serializer.fromJson<String?>(json['authorName']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'routeId': serializer.toJson<String>(routeId),
      'wallId': serializer.toJson<String>(wallId),
      'climbedAt': serializer.toJson<int>(climbedAt),
      'style': serializer.toJson<String>(style),
      'notes': serializer.toJson<String?>(notes),
      'gradeOpinion': serializer.toJson<String?>(gradeOpinion),
      'visibility': serializer.toJson<String>(visibility),
      'authorName': serializer.toJson<String?>(authorName),
    };
  }

  Ascent copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    String? routeId,
    String? wallId,
    int? climbedAt,
    String? style,
    Value<String?> notes = const Value.absent(),
    Value<String?> gradeOpinion = const Value.absent(),
    String? visibility,
    Value<String?> authorName = const Value.absent(),
  }) => Ascent(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    routeId: routeId ?? this.routeId,
    wallId: wallId ?? this.wallId,
    climbedAt: climbedAt ?? this.climbedAt,
    style: style ?? this.style,
    notes: notes.present ? notes.value : this.notes,
    gradeOpinion: gradeOpinion.present ? gradeOpinion.value : this.gradeOpinion,
    visibility: visibility ?? this.visibility,
    authorName: authorName.present ? authorName.value : this.authorName,
  );
  Ascent copyWithCompanion(AscentsCompanion data) {
    return Ascent(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      climbedAt: data.climbedAt.present ? data.climbedAt.value : this.climbedAt,
      style: data.style.present ? data.style.value : this.style,
      notes: data.notes.present ? data.notes.value : this.notes,
      gradeOpinion: data.gradeOpinion.present
          ? data.gradeOpinion.value
          : this.gradeOpinion,
      visibility: data.visibility.present
          ? data.visibility.value
          : this.visibility,
      authorName: data.authorName.present
          ? data.authorName.value
          : this.authorName,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Ascent(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('routeId: $routeId, ')
          ..write('wallId: $wallId, ')
          ..write('climbedAt: $climbedAt, ')
          ..write('style: $style, ')
          ..write('notes: $notes, ')
          ..write('gradeOpinion: $gradeOpinion, ')
          ..write('visibility: $visibility, ')
          ..write('authorName: $authorName')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    routeId,
    wallId,
    climbedAt,
    style,
    notes,
    gradeOpinion,
    visibility,
    authorName,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Ascent &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.routeId == this.routeId &&
          other.wallId == this.wallId &&
          other.climbedAt == this.climbedAt &&
          other.style == this.style &&
          other.notes == this.notes &&
          other.gradeOpinion == this.gradeOpinion &&
          other.visibility == this.visibility &&
          other.authorName == this.authorName);
}

class AscentsCompanion extends UpdateCompanion<Ascent> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String> routeId;
  final Value<String> wallId;
  final Value<int> climbedAt;
  final Value<String> style;
  final Value<String?> notes;
  final Value<String?> gradeOpinion;
  final Value<String> visibility;
  final Value<String?> authorName;
  final Value<int> rowid;
  const AscentsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.routeId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.climbedAt = const Value.absent(),
    this.style = const Value.absent(),
    this.notes = const Value.absent(),
    this.gradeOpinion = const Value.absent(),
    this.visibility = const Value.absent(),
    this.authorName = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AscentsCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    required String routeId,
    required String wallId,
    required int climbedAt,
    required String style,
    this.notes = const Value.absent(),
    this.gradeOpinion = const Value.absent(),
    this.visibility = const Value.absent(),
    this.authorName = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       routeId = Value(routeId),
       wallId = Value(wallId),
       climbedAt = Value(climbedAt),
       style = Value(style);
  static Insertable<Ascent> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? routeId,
    Expression<String>? wallId,
    Expression<int>? climbedAt,
    Expression<String>? style,
    Expression<String>? notes,
    Expression<String>? gradeOpinion,
    Expression<String>? visibility,
    Expression<String>? authorName,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (routeId != null) 'route_id': routeId,
      if (wallId != null) 'wall_id': wallId,
      if (climbedAt != null) 'climbed_at': climbedAt,
      if (style != null) 'style': style,
      if (notes != null) 'notes': notes,
      if (gradeOpinion != null) 'grade_opinion': gradeOpinion,
      if (visibility != null) 'visibility': visibility,
      if (authorName != null) 'author_name': authorName,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AscentsCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String>? routeId,
    Value<String>? wallId,
    Value<int>? climbedAt,
    Value<String>? style,
    Value<String?>? notes,
    Value<String?>? gradeOpinion,
    Value<String>? visibility,
    Value<String?>? authorName,
    Value<int>? rowid,
  }) {
    return AscentsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      routeId: routeId ?? this.routeId,
      wallId: wallId ?? this.wallId,
      climbedAt: climbedAt ?? this.climbedAt,
      style: style ?? this.style,
      notes: notes ?? this.notes,
      gradeOpinion: gradeOpinion ?? this.gradeOpinion,
      visibility: visibility ?? this.visibility,
      authorName: authorName ?? this.authorName,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (climbedAt.present) {
      map['climbed_at'] = Variable<int>(climbedAt.value);
    }
    if (style.present) {
      map['style'] = Variable<String>(style.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (gradeOpinion.present) {
      map['grade_opinion'] = Variable<String>(gradeOpinion.value);
    }
    if (visibility.present) {
      map['visibility'] = Variable<String>(visibility.value);
    }
    if (authorName.present) {
      map['author_name'] = Variable<String>(authorName.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AscentsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('routeId: $routeId, ')
          ..write('wallId: $wallId, ')
          ..write('climbedAt: $climbedAt, ')
          ..write('style: $style, ')
          ..write('notes: $notes, ')
          ..write('gradeOpinion: $gradeOpinion, ')
          ..write('visibility: $visibility, ')
          ..write('authorName: $authorName, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CommentsTable extends Comments with TableInfo<$CommentsTable, Comment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CommentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES walls (id)',
    ),
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authorNameMeta = const VerificationMeta(
    'authorName',
  );
  @override
  late final GeneratedColumn<String> authorName = GeneratedColumn<String>(
    'author_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ascentIdMeta = const VerificationMeta(
    'ascentId',
  );
  @override
  late final GeneratedColumn<String> ascentId = GeneratedColumn<String>(
    'ascent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES ascents (id)',
    ),
  );
  static const VerificationMeta _mentionedUidsMeta = const VerificationMeta(
    'mentionedUids',
  );
  @override
  late final GeneratedColumn<String> mentionedUids = GeneratedColumn<String>(
    'mentioned_uids',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    body,
    authorName,
    ascentId,
    mentionedUids,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'comments';
  @override
  VerificationContext validateIntegrity(
    Insertable<Comment> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('author_name')) {
      context.handle(
        _authorNameMeta,
        authorName.isAcceptableOrUnknown(data['author_name']!, _authorNameMeta),
      );
    }
    if (data.containsKey('ascent_id')) {
      context.handle(
        _ascentIdMeta,
        ascentId.isAcceptableOrUnknown(data['ascent_id']!, _ascentIdMeta),
      );
    }
    if (data.containsKey('mentioned_uids')) {
      context.handle(
        _mentionedUidsMeta,
        mentionedUids.isAcceptableOrUnknown(
          data['mentioned_uids']!,
          _mentionedUidsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Comment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Comment(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      ),
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      authorName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_name'],
      ),
      ascentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ascent_id'],
      ),
      mentionedUids: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mentioned_uids'],
      ),
    );
  }

  @override
  $CommentsTable createAlias(String alias) {
    return $CommentsTable(attachedDatabase, alias);
  }
}

class Comment extends DataClass implements Insertable<Comment> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;

  /// Nullable as of Feature #12 (public opt-in ascent logs): a comment now
  /// attaches to EITHER a wall (topo) OR an ascent, never both — see
  /// [ascentId]. Pre-existing rows keep their wallId; only newly-created
  /// ascent comments leave this `null`.
  final String? wallId;
  final String body;
  final String? authorName;

  /// FK making this comment attach to an ascent log rather than a wall —
  /// see [wallId]. App-level invariant "exactly one of wallId/ascentId is
  /// set" is enforced by the repositories, NOT a DB CHECK constraint.
  /// `null` for every pre-Feature-#12 comment (all wall-attached).
  final String? ascentId;

  /// The uids this comment tags, as a JSON array of strings (`["uid-a"]`),
  /// or `null` for the overwhelming majority of comments, which tag nobody.
  ///
  /// **Uids, not names.** A mention could have been stored as the `@name` text
  /// already in [body] and re-resolved at render time, and that would have
  /// been less code. It would also have broken silently the first time
  /// somebody renamed themselves — display names are editable (#18), so the
  /// text is a description of who they were that day, not a reference. Two
  /// climbers may also legitimately choose the same display name, which a
  /// text match cannot tell apart and a uid can.
  ///
  /// A JSON array in one column rather than a join table: a mention has no
  /// attributes of its own, is only ever read as "who does this comment tag",
  /// and travels with the comment through the sync engine's full-row re-push
  /// (decision D-4) for free. A join table would need its own sync plumbing to
  /// carry exactly the same information.
  final String? mentionedUids;
  const Comment({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    this.wallId,
    required this.body,
    this.authorName,
    this.ascentId,
    this.mentionedUids,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || wallId != null) {
      map['wall_id'] = Variable<String>(wallId);
    }
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || authorName != null) {
      map['author_name'] = Variable<String>(authorName);
    }
    if (!nullToAbsent || ascentId != null) {
      map['ascent_id'] = Variable<String>(ascentId);
    }
    if (!nullToAbsent || mentionedUids != null) {
      map['mentioned_uids'] = Variable<String>(mentionedUids);
    }
    return map;
  }

  CommentsCompanion toCompanion(bool nullToAbsent) {
    return CommentsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      wallId: wallId == null && nullToAbsent
          ? const Value.absent()
          : Value(wallId),
      body: Value(body),
      authorName: authorName == null && nullToAbsent
          ? const Value.absent()
          : Value(authorName),
      ascentId: ascentId == null && nullToAbsent
          ? const Value.absent()
          : Value(ascentId),
      mentionedUids: mentionedUids == null && nullToAbsent
          ? const Value.absent()
          : Value(mentionedUids),
    );
  }

  factory Comment.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Comment(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      wallId: serializer.fromJson<String?>(json['wallId']),
      body: serializer.fromJson<String>(json['body']),
      authorName: serializer.fromJson<String?>(json['authorName']),
      ascentId: serializer.fromJson<String?>(json['ascentId']),
      mentionedUids: serializer.fromJson<String?>(json['mentionedUids']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'wallId': serializer.toJson<String?>(wallId),
      'body': serializer.toJson<String>(body),
      'authorName': serializer.toJson<String?>(authorName),
      'ascentId': serializer.toJson<String?>(ascentId),
      'mentionedUids': serializer.toJson<String?>(mentionedUids),
    };
  }

  Comment copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    Value<String?> wallId = const Value.absent(),
    String? body,
    Value<String?> authorName = const Value.absent(),
    Value<String?> ascentId = const Value.absent(),
    Value<String?> mentionedUids = const Value.absent(),
  }) => Comment(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    wallId: wallId.present ? wallId.value : this.wallId,
    body: body ?? this.body,
    authorName: authorName.present ? authorName.value : this.authorName,
    ascentId: ascentId.present ? ascentId.value : this.ascentId,
    mentionedUids: mentionedUids.present
        ? mentionedUids.value
        : this.mentionedUids,
  );
  Comment copyWithCompanion(CommentsCompanion data) {
    return Comment(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      body: data.body.present ? data.body.value : this.body,
      authorName: data.authorName.present
          ? data.authorName.value
          : this.authorName,
      ascentId: data.ascentId.present ? data.ascentId.value : this.ascentId,
      mentionedUids: data.mentionedUids.present
          ? data.mentionedUids.value
          : this.mentionedUids,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Comment(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('body: $body, ')
          ..write('authorName: $authorName, ')
          ..write('ascentId: $ascentId, ')
          ..write('mentionedUids: $mentionedUids')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    body,
    authorName,
    ascentId,
    mentionedUids,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Comment &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.wallId == this.wallId &&
          other.body == this.body &&
          other.authorName == this.authorName &&
          other.ascentId == this.ascentId &&
          other.mentionedUids == this.mentionedUids);
}

class CommentsCompanion extends UpdateCompanion<Comment> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String?> wallId;
  final Value<String> body;
  final Value<String?> authorName;
  final Value<String?> ascentId;
  final Value<String?> mentionedUids;
  final Value<int> rowid;
  const CommentsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.body = const Value.absent(),
    this.authorName = const Value.absent(),
    this.ascentId = const Value.absent(),
    this.mentionedUids = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CommentsCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.wallId = const Value.absent(),
    required String body,
    this.authorName = const Value.absent(),
    this.ascentId = const Value.absent(),
    this.mentionedUids = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       body = Value(body);
  static Insertable<Comment> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? wallId,
    Expression<String>? body,
    Expression<String>? authorName,
    Expression<String>? ascentId,
    Expression<String>? mentionedUids,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (wallId != null) 'wall_id': wallId,
      if (body != null) 'body': body,
      if (authorName != null) 'author_name': authorName,
      if (ascentId != null) 'ascent_id': ascentId,
      if (mentionedUids != null) 'mentioned_uids': mentionedUids,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CommentsCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String?>? wallId,
    Value<String>? body,
    Value<String?>? authorName,
    Value<String?>? ascentId,
    Value<String?>? mentionedUids,
    Value<int>? rowid,
  }) {
    return CommentsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      wallId: wallId ?? this.wallId,
      body: body ?? this.body,
      authorName: authorName ?? this.authorName,
      ascentId: ascentId ?? this.ascentId,
      mentionedUids: mentionedUids ?? this.mentionedUids,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (authorName.present) {
      map['author_name'] = Variable<String>(authorName.value);
    }
    if (ascentId.present) {
      map['ascent_id'] = Variable<String>(ascentId.value);
    }
    if (mentionedUids.present) {
      map['mentioned_uids'] = Variable<String>(mentionedUids.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CommentsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('body: $body, ')
          ..write('authorName: $authorName, ')
          ..write('ascentId: $ascentId, ')
          ..write('mentionedUids: $mentionedUids, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LikesTable extends Likes with TableInfo<$LikesTable, Like> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LikesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES walls (id)',
    ),
  );
  static const VerificationMeta _ascentIdMeta = const VerificationMeta(
    'ascentId',
  );
  @override
  late final GeneratedColumn<String> ascentId = GeneratedColumn<String>(
    'ascent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES ascents (id)',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    ascentId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'likes';
  @override
  VerificationContext validateIntegrity(
    Insertable<Like> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    }
    if (data.containsKey('ascent_id')) {
      context.handle(
        _ascentIdMeta,
        ascentId.isAcceptableOrUnknown(data['ascent_id']!, _ascentIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Like map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Like(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      ),
      ascentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ascent_id'],
      ),
    );
  }

  @override
  $LikesTable createAlias(String alias) {
    return $LikesTable(attachedDatabase, alias);
  }
}

class Like extends DataClass implements Insertable<Like> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;

  /// Nullable as of Feature #12 (public opt-in ascent logs): a like now
  /// attaches to EITHER a wall (topo) OR an ascent, never both — see
  /// [ascentId]. Pre-existing rows keep their wallId; only newly-created
  /// ascent likes leave this `null`.
  final String? wallId;

  /// FK making this like attach to an ascent log rather than a wall — see
  /// [wallId]. App-level invariant "exactly one of wallId/ascentId is set"
  /// is enforced by the repositories, NOT a DB CHECK constraint. `null`
  /// for every pre-Feature-#12 like (all wall-attached).
  final String? ascentId;
  const Like({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    this.wallId,
    this.ascentId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || wallId != null) {
      map['wall_id'] = Variable<String>(wallId);
    }
    if (!nullToAbsent || ascentId != null) {
      map['ascent_id'] = Variable<String>(ascentId);
    }
    return map;
  }

  LikesCompanion toCompanion(bool nullToAbsent) {
    return LikesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      wallId: wallId == null && nullToAbsent
          ? const Value.absent()
          : Value(wallId),
      ascentId: ascentId == null && nullToAbsent
          ? const Value.absent()
          : Value(ascentId),
    );
  }

  factory Like.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Like(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      wallId: serializer.fromJson<String?>(json['wallId']),
      ascentId: serializer.fromJson<String?>(json['ascentId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'wallId': serializer.toJson<String?>(wallId),
      'ascentId': serializer.toJson<String?>(ascentId),
    };
  }

  Like copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    Value<String?> wallId = const Value.absent(),
    Value<String?> ascentId = const Value.absent(),
  }) => Like(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    wallId: wallId.present ? wallId.value : this.wallId,
    ascentId: ascentId.present ? ascentId.value : this.ascentId,
  );
  Like copyWithCompanion(LikesCompanion data) {
    return Like(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      ascentId: data.ascentId.present ? data.ascentId.value : this.ascentId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Like(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('ascentId: $ascentId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    wallId,
    ascentId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Like &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.wallId == this.wallId &&
          other.ascentId == this.ascentId);
}

class LikesCompanion extends UpdateCompanion<Like> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String?> wallId;
  final Value<String?> ascentId;
  final Value<int> rowid;
  const LikesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.ascentId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LikesCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.ascentId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Like> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? wallId,
    Expression<String>? ascentId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (wallId != null) 'wall_id': wallId,
      if (ascentId != null) 'ascent_id': ascentId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LikesCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String?>? wallId,
    Value<String?>? ascentId,
    Value<int>? rowid,
  }) {
    return LikesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      wallId: wallId ?? this.wallId,
      ascentId: ascentId ?? this.ascentId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (ascentId.present) {
      map['ascent_id'] = Variable<String>(ascentId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LikesCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('wallId: $wallId, ')
          ..write('ascentId: $ascentId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProfilesTable extends Profiles with TableInfo<$ProfilesTable, Profile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _avatarUrlMeta = const VerificationMeta(
    'avatarUrl',
  );
  @override
  late final GeneratedColumn<String> avatarUrl = GeneratedColumn<String>(
    'avatar_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    displayName,
    avatarUrl,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<Profile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('avatar_url')) {
      context.handle(
        _avatarUrlMeta,
        avatarUrl.isAcceptableOrUnknown(data['avatar_url']!, _avatarUrlMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Profile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Profile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      ),
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      ),
      avatarUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_url'],
      ),
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class Profile extends DataClass implements Insertable<Profile> {
  final String id;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? remoteId;
  final bool dirty;
  final String? ownerId;

  /// The user-chosen display name shown in place of their email/uid
  /// wherever another user's identity is surfaced (Community feed,
  /// comments, ascent logs, ...). `null` until the user sets one.
  final String? displayName;

  /// The user's profile picture, or `null` for "no picture" (callers fall
  /// back to the initials chip). Two shapes are valid and both render:
  ///
  ///  - an `https://` URL — what an OAuth provider hands over in the
  ///    session's user metadata (Google's `avatar_url`/`picture`). Not
  ///    stored here by the app; it is read live off the session and only
  ///    used when this column is null, so it can never go stale.
  ///  - a `data:image/...;base64,...` URL — a picture the user chose
  ///    themselves. Stored inline rather than uploaded to Supabase Storage
  ///    because that needs no bucket, no storage RLS and no second failure
  ///    mode: the picture is downscaled to at most 512px and rides the
  ///    profile row through the EXISTING sync engine, so it works offline
  ///    (write now, push on the next pull, per decision D-4's no-outbox
  ///    model) and arrives with any other user's profile for free.
  final String? avatarUrl;
  const Profile({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.remoteId,
    required this.dirty,
    this.ownerId,
    this.displayName,
    this.avatarUrl,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['dirty'] = Variable<bool>(dirty);
    if (!nullToAbsent || ownerId != null) {
      map['owner_id'] = Variable<String>(ownerId);
    }
    if (!nullToAbsent || displayName != null) {
      map['display_name'] = Variable<String>(displayName);
    }
    if (!nullToAbsent || avatarUrl != null) {
      map['avatar_url'] = Variable<String>(avatarUrl);
    }
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      dirty: Value(dirty),
      ownerId: ownerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerId),
      displayName: displayName == null && nullToAbsent
          ? const Value.absent()
          : Value(displayName),
      avatarUrl: avatarUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(avatarUrl),
    );
  }

  factory Profile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Profile(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerId: serializer.fromJson<String?>(json['ownerId']),
      displayName: serializer.fromJson<String?>(json['displayName']),
      avatarUrl: serializer.fromJson<String?>(json['avatarUrl']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'remoteId': serializer.toJson<String?>(remoteId),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerId': serializer.toJson<String?>(ownerId),
      'displayName': serializer.toJson<String?>(displayName),
      'avatarUrl': serializer.toJson<String?>(avatarUrl),
    };
  }

  Profile copyWith({
    String? id,
    int? createdAt,
    int? updatedAt,
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    bool? dirty,
    Value<String?> ownerId = const Value.absent(),
    Value<String?> displayName = const Value.absent(),
    Value<String?> avatarUrl = const Value.absent(),
  }) => Profile(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    dirty: dirty ?? this.dirty,
    ownerId: ownerId.present ? ownerId.value : this.ownerId,
    displayName: displayName.present ? displayName.value : this.displayName,
    avatarUrl: avatarUrl.present ? avatarUrl.value : this.avatarUrl,
  );
  Profile copyWithCompanion(ProfilesCompanion data) {
    return Profile(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      avatarUrl: data.avatarUrl.present ? data.avatarUrl.value : this.avatarUrl,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Profile(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('displayName: $displayName, ')
          ..write('avatarUrl: $avatarUrl')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    updatedAt,
    deletedAt,
    remoteId,
    dirty,
    ownerId,
    displayName,
    avatarUrl,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Profile &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.remoteId == this.remoteId &&
          other.dirty == this.dirty &&
          other.ownerId == this.ownerId &&
          other.displayName == this.displayName &&
          other.avatarUrl == this.avatarUrl);
}

class ProfilesCompanion extends UpdateCompanion<Profile> {
  final Value<String> id;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> deletedAt;
  final Value<String?> remoteId;
  final Value<bool> dirty;
  final Value<String?> ownerId;
  final Value<String?> displayName;
  final Value<String?> avatarUrl;
  final Value<int> rowid;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatarUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfilesCompanion.insert({
    required String id,
    required int createdAt,
    required int updatedAt,
    this.deletedAt = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatarUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Profile> custom({
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? deletedAt,
    Expression<String>? remoteId,
    Expression<bool>? dirty,
    Expression<String>? ownerId,
    Expression<String>? displayName,
    Expression<String>? avatarUrl,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (remoteId != null) 'remote_id': remoteId,
      if (dirty != null) 'dirty': dirty,
      if (ownerId != null) 'owner_id': ownerId,
      if (displayName != null) 'display_name': displayName,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfilesCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? deletedAt,
    Value<String?>? remoteId,
    Value<bool>? dirty,
    Value<String?>? ownerId,
    Value<String?>? displayName,
    Value<String?>? avatarUrl,
    Value<int>? rowid,
  }) {
    return ProfilesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      remoteId: remoteId ?? this.remoteId,
      dirty: dirty ?? this.dirty,
      ownerId: ownerId ?? this.ownerId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (avatarUrl.present) {
      map['avatar_url'] = Variable<String>(avatarUrl.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('remoteId: $remoteId, ')
          ..write('dirty: $dirty, ')
          ..write('ownerId: $ownerId, ')
          ..write('displayName: $displayName, ')
          ..write('avatarUrl: $avatarUrl, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _settingKeyMeta = const VerificationMeta(
    'settingKey',
  );
  @override
  late final GeneratedColumn<String> settingKey = GeneratedColumn<String>(
    'setting_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _settingValueMeta = const VerificationMeta(
    'settingValue',
  );
  @override
  late final GeneratedColumn<String> settingValue = GeneratedColumn<String>(
    'setting_value',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [settingKey, settingValue, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('setting_key')) {
      context.handle(
        _settingKeyMeta,
        settingKey.isAcceptableOrUnknown(data['setting_key']!, _settingKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_settingKeyMeta);
    }
    if (data.containsKey('setting_value')) {
      context.handle(
        _settingValueMeta,
        settingValue.isAcceptableOrUnknown(
          data['setting_value']!,
          _settingValueMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {settingKey};
  @override
  AppSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSettingRow(
      settingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_key'],
      )!,
      settingValue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_value'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }
}

class AppSettingRow extends DataClass implements Insertable<AppSettingRow> {
  /// Opaque setting name. Not called `key` — `KEY` is a SQLite keyword and
  /// `key` collides with `Widget.key` conventions in generated code.
  final String settingKey;

  /// The setting's value, always TEXT (callers encode/decode). Nullable so a
  /// present-but-unset key is expressible; `SettingsStore.remove` deletes the
  /// row outright rather than nulling it.
  final String? settingValue;

  /// ms-epoch of the last write, from the injected `nowMs` clock seam — purely
  /// diagnostic (nothing reads it for behavior).
  final int updatedAt;
  const AppSettingRow({
    required this.settingKey,
    this.settingValue,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['setting_key'] = Variable<String>(settingKey);
    if (!nullToAbsent || settingValue != null) {
      map['setting_value'] = Variable<String>(settingValue);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(
      settingKey: Value(settingKey),
      settingValue: settingValue == null && nullToAbsent
          ? const Value.absent()
          : Value(settingValue),
      updatedAt: Value(updatedAt),
    );
  }

  factory AppSettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSettingRow(
      settingKey: serializer.fromJson<String>(json['settingKey']),
      settingValue: serializer.fromJson<String?>(json['settingValue']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'settingKey': serializer.toJson<String>(settingKey),
      'settingValue': serializer.toJson<String?>(settingValue),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  AppSettingRow copyWith({
    String? settingKey,
    Value<String?> settingValue = const Value.absent(),
    int? updatedAt,
  }) => AppSettingRow(
    settingKey: settingKey ?? this.settingKey,
    settingValue: settingValue.present ? settingValue.value : this.settingValue,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AppSettingRow copyWithCompanion(AppSettingsCompanion data) {
    return AppSettingRow(
      settingKey: data.settingKey.present
          ? data.settingKey.value
          : this.settingKey,
      settingValue: data.settingValue.present
          ? data.settingValue.value
          : this.settingValue,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingRow(')
          ..write('settingKey: $settingKey, ')
          ..write('settingValue: $settingValue, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(settingKey, settingValue, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSettingRow &&
          other.settingKey == this.settingKey &&
          other.settingValue == this.settingValue &&
          other.updatedAt == this.updatedAt);
}

class AppSettingsCompanion extends UpdateCompanion<AppSettingRow> {
  final Value<String> settingKey;
  final Value<String?> settingValue;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.settingKey = const Value.absent(),
    this.settingValue = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String settingKey,
    this.settingValue = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : settingKey = Value(settingKey),
       updatedAt = Value(updatedAt);
  static Insertable<AppSettingRow> custom({
    Expression<String>? settingKey,
    Expression<String>? settingValue,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (settingKey != null) 'setting_key': settingKey,
      if (settingValue != null) 'setting_value': settingValue,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingsCompanion copyWith({
    Value<String>? settingKey,
    Value<String?>? settingValue,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
      settingKey: settingKey ?? this.settingKey,
      settingValue: settingValue ?? this.settingValue,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (settingKey.present) {
      map['setting_key'] = Variable<String>(settingKey.value);
    }
    if (settingValue.present) {
      map['setting_value'] = Variable<String>(settingValue.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsCompanion(')
          ..write('settingKey: $settingKey, ')
          ..write('settingValue: $settingValue, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WallModerationRowsTable extends WallModerationRows
    with TableInfo<$WallModerationRowsTable, WallModerationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WallModerationRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _submittedAtMeta = const VerificationMeta(
    'submittedAt',
  );
  @override
  late final GeneratedColumn<int> submittedAt = GeneratedColumn<int>(
    'submitted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reviewedAtMeta = const VerificationMeta(
    'reviewedAt',
  );
  @override
  late final GeneratedColumn<int> reviewedAt = GeneratedColumn<int>(
    'reviewed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reviewerIdMeta = const VerificationMeta(
    'reviewerId',
  );
  @override
  late final GeneratedColumn<String> reviewerId = GeneratedColumn<String>(
    'reviewer_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rejectionReasonMeta = const VerificationMeta(
    'rejectionReason',
  );
  @override
  late final GeneratedColumn<String> rejectionReason = GeneratedColumn<String>(
    'rejection_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _withdrawRequestedAtMeta =
      const VerificationMeta('withdrawRequestedAt');
  @override
  late final GeneratedColumn<int> withdrawRequestedAt = GeneratedColumn<int>(
    'withdraw_requested_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    wallId,
    state,
    submittedAt,
    reviewedAt,
    reviewerId,
    rejectionReason,
    withdrawRequestedAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'wall_moderation_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<WallModerationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    } else if (isInserting) {
      context.missing(_wallIdMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('submitted_at')) {
      context.handle(
        _submittedAtMeta,
        submittedAt.isAcceptableOrUnknown(
          data['submitted_at']!,
          _submittedAtMeta,
        ),
      );
    }
    if (data.containsKey('reviewed_at')) {
      context.handle(
        _reviewedAtMeta,
        reviewedAt.isAcceptableOrUnknown(data['reviewed_at']!, _reviewedAtMeta),
      );
    }
    if (data.containsKey('reviewer_id')) {
      context.handle(
        _reviewerIdMeta,
        reviewerId.isAcceptableOrUnknown(data['reviewer_id']!, _reviewerIdMeta),
      );
    }
    if (data.containsKey('rejection_reason')) {
      context.handle(
        _rejectionReasonMeta,
        rejectionReason.isAcceptableOrUnknown(
          data['rejection_reason']!,
          _rejectionReasonMeta,
        ),
      );
    }
    if (data.containsKey('withdraw_requested_at')) {
      context.handle(
        _withdrawRequestedAtMeta,
        withdrawRequestedAt.isAcceptableOrUnknown(
          data['withdraw_requested_at']!,
          _withdrawRequestedAtMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {wallId};
  @override
  WallModerationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WallModerationRow(
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      submittedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}submitted_at'],
      ),
      reviewedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reviewed_at'],
      ),
      reviewerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reviewer_id'],
      ),
      rejectionReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rejection_reason'],
      ),
      withdrawRequestedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}withdraw_requested_at'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $WallModerationRowsTable createAlias(String alias) {
    return $WallModerationRowsTable(attachedDatabase, alias);
  }
}

class WallModerationRow extends DataClass
    implements Insertable<WallModerationRow> {
  /// The moderated wall's id. Not a Drift `references(Walls, #id)` FK: rows
  /// arrive from the server pull, and a moderation row can legitimately land
  /// for a wall this device has not pulled yet (or has since dropped), which
  /// a real FK with `PRAGMA foreign_keys = ON` would reject outright.
  final String wallId;

  /// `draft` | `pending` | `published` | `rejected` | `withdrawn` | `removed`.
  /// Stored as the raw server string and parsed at the edge (see
  /// `ModerationState.fromWire`) so an unknown future state degrades to a
  /// safe default instead of throwing on read.
  final String state;
  final int? submittedAt;
  final int? reviewedAt;
  final String? reviewerId;

  /// Why a submission was rejected, shown to the owner. A silent rejection
  /// teaches nobody anything.
  final String? rejectionReason;

  /// When the owner asked to withdraw, or null. The topo stays visible for
  /// 10 days from this instant (C-3) — a window the SERVER evaluates inside
  /// its visibility predicate, so this column is for showing the countdown,
  /// never for deciding visibility.
  final int? withdrawRequestedAt;
  final int updatedAt;
  const WallModerationRow({
    required this.wallId,
    required this.state,
    this.submittedAt,
    this.reviewedAt,
    this.reviewerId,
    this.rejectionReason,
    this.withdrawRequestedAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['wall_id'] = Variable<String>(wallId);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || submittedAt != null) {
      map['submitted_at'] = Variable<int>(submittedAt);
    }
    if (!nullToAbsent || reviewedAt != null) {
      map['reviewed_at'] = Variable<int>(reviewedAt);
    }
    if (!nullToAbsent || reviewerId != null) {
      map['reviewer_id'] = Variable<String>(reviewerId);
    }
    if (!nullToAbsent || rejectionReason != null) {
      map['rejection_reason'] = Variable<String>(rejectionReason);
    }
    if (!nullToAbsent || withdrawRequestedAt != null) {
      map['withdraw_requested_at'] = Variable<int>(withdrawRequestedAt);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  WallModerationRowsCompanion toCompanion(bool nullToAbsent) {
    return WallModerationRowsCompanion(
      wallId: Value(wallId),
      state: Value(state),
      submittedAt: submittedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(submittedAt),
      reviewedAt: reviewedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(reviewedAt),
      reviewerId: reviewerId == null && nullToAbsent
          ? const Value.absent()
          : Value(reviewerId),
      rejectionReason: rejectionReason == null && nullToAbsent
          ? const Value.absent()
          : Value(rejectionReason),
      withdrawRequestedAt: withdrawRequestedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(withdrawRequestedAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory WallModerationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WallModerationRow(
      wallId: serializer.fromJson<String>(json['wallId']),
      state: serializer.fromJson<String>(json['state']),
      submittedAt: serializer.fromJson<int?>(json['submittedAt']),
      reviewedAt: serializer.fromJson<int?>(json['reviewedAt']),
      reviewerId: serializer.fromJson<String?>(json['reviewerId']),
      rejectionReason: serializer.fromJson<String?>(json['rejectionReason']),
      withdrawRequestedAt: serializer.fromJson<int?>(
        json['withdrawRequestedAt'],
      ),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'wallId': serializer.toJson<String>(wallId),
      'state': serializer.toJson<String>(state),
      'submittedAt': serializer.toJson<int?>(submittedAt),
      'reviewedAt': serializer.toJson<int?>(reviewedAt),
      'reviewerId': serializer.toJson<String?>(reviewerId),
      'rejectionReason': serializer.toJson<String?>(rejectionReason),
      'withdrawRequestedAt': serializer.toJson<int?>(withdrawRequestedAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  WallModerationRow copyWith({
    String? wallId,
    String? state,
    Value<int?> submittedAt = const Value.absent(),
    Value<int?> reviewedAt = const Value.absent(),
    Value<String?> reviewerId = const Value.absent(),
    Value<String?> rejectionReason = const Value.absent(),
    Value<int?> withdrawRequestedAt = const Value.absent(),
    int? updatedAt,
  }) => WallModerationRow(
    wallId: wallId ?? this.wallId,
    state: state ?? this.state,
    submittedAt: submittedAt.present ? submittedAt.value : this.submittedAt,
    reviewedAt: reviewedAt.present ? reviewedAt.value : this.reviewedAt,
    reviewerId: reviewerId.present ? reviewerId.value : this.reviewerId,
    rejectionReason: rejectionReason.present
        ? rejectionReason.value
        : this.rejectionReason,
    withdrawRequestedAt: withdrawRequestedAt.present
        ? withdrawRequestedAt.value
        : this.withdrawRequestedAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  WallModerationRow copyWithCompanion(WallModerationRowsCompanion data) {
    return WallModerationRow(
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      state: data.state.present ? data.state.value : this.state,
      submittedAt: data.submittedAt.present
          ? data.submittedAt.value
          : this.submittedAt,
      reviewedAt: data.reviewedAt.present
          ? data.reviewedAt.value
          : this.reviewedAt,
      reviewerId: data.reviewerId.present
          ? data.reviewerId.value
          : this.reviewerId,
      rejectionReason: data.rejectionReason.present
          ? data.rejectionReason.value
          : this.rejectionReason,
      withdrawRequestedAt: data.withdrawRequestedAt.present
          ? data.withdrawRequestedAt.value
          : this.withdrawRequestedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WallModerationRow(')
          ..write('wallId: $wallId, ')
          ..write('state: $state, ')
          ..write('submittedAt: $submittedAt, ')
          ..write('reviewedAt: $reviewedAt, ')
          ..write('reviewerId: $reviewerId, ')
          ..write('rejectionReason: $rejectionReason, ')
          ..write('withdrawRequestedAt: $withdrawRequestedAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    wallId,
    state,
    submittedAt,
    reviewedAt,
    reviewerId,
    rejectionReason,
    withdrawRequestedAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WallModerationRow &&
          other.wallId == this.wallId &&
          other.state == this.state &&
          other.submittedAt == this.submittedAt &&
          other.reviewedAt == this.reviewedAt &&
          other.reviewerId == this.reviewerId &&
          other.rejectionReason == this.rejectionReason &&
          other.withdrawRequestedAt == this.withdrawRequestedAt &&
          other.updatedAt == this.updatedAt);
}

class WallModerationRowsCompanion extends UpdateCompanion<WallModerationRow> {
  final Value<String> wallId;
  final Value<String> state;
  final Value<int?> submittedAt;
  final Value<int?> reviewedAt;
  final Value<String?> reviewerId;
  final Value<String?> rejectionReason;
  final Value<int?> withdrawRequestedAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const WallModerationRowsCompanion({
    this.wallId = const Value.absent(),
    this.state = const Value.absent(),
    this.submittedAt = const Value.absent(),
    this.reviewedAt = const Value.absent(),
    this.reviewerId = const Value.absent(),
    this.rejectionReason = const Value.absent(),
    this.withdrawRequestedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WallModerationRowsCompanion.insert({
    required String wallId,
    required String state,
    this.submittedAt = const Value.absent(),
    this.reviewedAt = const Value.absent(),
    this.reviewerId = const Value.absent(),
    this.rejectionReason = const Value.absent(),
    this.withdrawRequestedAt = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : wallId = Value(wallId),
       state = Value(state),
       updatedAt = Value(updatedAt);
  static Insertable<WallModerationRow> custom({
    Expression<String>? wallId,
    Expression<String>? state,
    Expression<int>? submittedAt,
    Expression<int>? reviewedAt,
    Expression<String>? reviewerId,
    Expression<String>? rejectionReason,
    Expression<int>? withdrawRequestedAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (wallId != null) 'wall_id': wallId,
      if (state != null) 'state': state,
      if (submittedAt != null) 'submitted_at': submittedAt,
      if (reviewedAt != null) 'reviewed_at': reviewedAt,
      if (reviewerId != null) 'reviewer_id': reviewerId,
      if (rejectionReason != null) 'rejection_reason': rejectionReason,
      if (withdrawRequestedAt != null)
        'withdraw_requested_at': withdrawRequestedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WallModerationRowsCompanion copyWith({
    Value<String>? wallId,
    Value<String>? state,
    Value<int?>? submittedAt,
    Value<int?>? reviewedAt,
    Value<String?>? reviewerId,
    Value<String?>? rejectionReason,
    Value<int?>? withdrawRequestedAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return WallModerationRowsCompanion(
      wallId: wallId ?? this.wallId,
      state: state ?? this.state,
      submittedAt: submittedAt ?? this.submittedAt,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      reviewerId: reviewerId ?? this.reviewerId,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      withdrawRequestedAt: withdrawRequestedAt ?? this.withdrawRequestedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (submittedAt.present) {
      map['submitted_at'] = Variable<int>(submittedAt.value);
    }
    if (reviewedAt.present) {
      map['reviewed_at'] = Variable<int>(reviewedAt.value);
    }
    if (reviewerId.present) {
      map['reviewer_id'] = Variable<String>(reviewerId.value);
    }
    if (rejectionReason.present) {
      map['rejection_reason'] = Variable<String>(rejectionReason.value);
    }
    if (withdrawRequestedAt.present) {
      map['withdraw_requested_at'] = Variable<int>(withdrawRequestedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WallModerationRowsCompanion(')
          ..write('wallId: $wallId, ')
          ..write('state: $state, ')
          ..write('submittedAt: $submittedAt, ')
          ..write('reviewedAt: $reviewedAt, ')
          ..write('reviewerId: $reviewerId, ')
          ..write('rejectionReason: $rejectionReason, ')
          ..write('withdrawRequestedAt: $withdrawRequestedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GradeOpinionRowsTable extends GradeOpinionRows
    with TableInfo<$GradeOpinionRowsTable, GradeOpinionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GradeOpinionRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _routeIdMeta = const VerificationMeta(
    'routeId',
  );
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
    'route_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authorIdMeta = const VerificationMeta(
    'authorId',
  );
  @override
  late final GeneratedColumn<String> authorId = GeneratedColumn<String>(
    'author_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _gradeSystemMeta = const VerificationMeta(
    'gradeSystem',
  );
  @override
  late final GeneratedColumn<String> gradeSystem = GeneratedColumn<String>(
    'grade_system',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _gradeRawMeta = const VerificationMeta(
    'gradeRaw',
  );
  @override
  late final GeneratedColumn<String> gradeRaw = GeneratedColumn<String>(
    'grade_raw',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _gradeSortKeyMeta = const VerificationMeta(
    'gradeSortKey',
  );
  @override
  late final GeneratedColumn<double> gradeSortKey = GeneratedColumn<double>(
    'grade_sort_key',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    routeId,
    authorId,
    gradeSystem,
    gradeRaw,
    gradeSortKey,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'grade_opinion_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<GradeOpinionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('route_id')) {
      context.handle(
        _routeIdMeta,
        routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_routeIdMeta);
    }
    if (data.containsKey('author_id')) {
      context.handle(
        _authorIdMeta,
        authorId.isAcceptableOrUnknown(data['author_id']!, _authorIdMeta),
      );
    } else if (isInserting) {
      context.missing(_authorIdMeta);
    }
    if (data.containsKey('grade_system')) {
      context.handle(
        _gradeSystemMeta,
        gradeSystem.isAcceptableOrUnknown(
          data['grade_system']!,
          _gradeSystemMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_gradeSystemMeta);
    }
    if (data.containsKey('grade_raw')) {
      context.handle(
        _gradeRawMeta,
        gradeRaw.isAcceptableOrUnknown(data['grade_raw']!, _gradeRawMeta),
      );
    } else if (isInserting) {
      context.missing(_gradeRawMeta);
    }
    if (data.containsKey('grade_sort_key')) {
      context.handle(
        _gradeSortKeyMeta,
        gradeSortKey.isAcceptableOrUnknown(
          data['grade_sort_key']!,
          _gradeSortKeyMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  GradeOpinionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GradeOpinionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      routeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_id'],
      )!,
      authorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_id'],
      )!,
      gradeSystem: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grade_system'],
      )!,
      gradeRaw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grade_raw'],
      )!,
      gradeSortKey: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}grade_sort_key'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $GradeOpinionRowsTable createAlias(String alias) {
    return $GradeOpinionRowsTable(attachedDatabase, alias);
  }
}

class GradeOpinionRow extends DataClass implements Insertable<GradeOpinionRow> {
  final String id;
  final String routeId;
  final String authorId;

  /// `french` | `uiaa`, as the raw server string. Parsed at the edge so an
  /// unknown future system degrades instead of throwing on read.
  final String gradeSystem;
  final String gradeRaw;

  /// Position on the shared cross-system scale. Stored rather than recomputed
  /// so a French and a UIAA opinion on one route stay directly comparable
  /// without the reader knowing either ladder.
  final double? gradeSortKey;
  final int createdAt;
  const GradeOpinionRow({
    required this.id,
    required this.routeId,
    required this.authorId,
    required this.gradeSystem,
    required this.gradeRaw,
    this.gradeSortKey,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['route_id'] = Variable<String>(routeId);
    map['author_id'] = Variable<String>(authorId);
    map['grade_system'] = Variable<String>(gradeSystem);
    map['grade_raw'] = Variable<String>(gradeRaw);
    if (!nullToAbsent || gradeSortKey != null) {
      map['grade_sort_key'] = Variable<double>(gradeSortKey);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  GradeOpinionRowsCompanion toCompanion(bool nullToAbsent) {
    return GradeOpinionRowsCompanion(
      id: Value(id),
      routeId: Value(routeId),
      authorId: Value(authorId),
      gradeSystem: Value(gradeSystem),
      gradeRaw: Value(gradeRaw),
      gradeSortKey: gradeSortKey == null && nullToAbsent
          ? const Value.absent()
          : Value(gradeSortKey),
      createdAt: Value(createdAt),
    );
  }

  factory GradeOpinionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GradeOpinionRow(
      id: serializer.fromJson<String>(json['id']),
      routeId: serializer.fromJson<String>(json['routeId']),
      authorId: serializer.fromJson<String>(json['authorId']),
      gradeSystem: serializer.fromJson<String>(json['gradeSystem']),
      gradeRaw: serializer.fromJson<String>(json['gradeRaw']),
      gradeSortKey: serializer.fromJson<double?>(json['gradeSortKey']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'routeId': serializer.toJson<String>(routeId),
      'authorId': serializer.toJson<String>(authorId),
      'gradeSystem': serializer.toJson<String>(gradeSystem),
      'gradeRaw': serializer.toJson<String>(gradeRaw),
      'gradeSortKey': serializer.toJson<double?>(gradeSortKey),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  GradeOpinionRow copyWith({
    String? id,
    String? routeId,
    String? authorId,
    String? gradeSystem,
    String? gradeRaw,
    Value<double?> gradeSortKey = const Value.absent(),
    int? createdAt,
  }) => GradeOpinionRow(
    id: id ?? this.id,
    routeId: routeId ?? this.routeId,
    authorId: authorId ?? this.authorId,
    gradeSystem: gradeSystem ?? this.gradeSystem,
    gradeRaw: gradeRaw ?? this.gradeRaw,
    gradeSortKey: gradeSortKey.present ? gradeSortKey.value : this.gradeSortKey,
    createdAt: createdAt ?? this.createdAt,
  );
  GradeOpinionRow copyWithCompanion(GradeOpinionRowsCompanion data) {
    return GradeOpinionRow(
      id: data.id.present ? data.id.value : this.id,
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      authorId: data.authorId.present ? data.authorId.value : this.authorId,
      gradeSystem: data.gradeSystem.present
          ? data.gradeSystem.value
          : this.gradeSystem,
      gradeRaw: data.gradeRaw.present ? data.gradeRaw.value : this.gradeRaw,
      gradeSortKey: data.gradeSortKey.present
          ? data.gradeSortKey.value
          : this.gradeSortKey,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GradeOpinionRow(')
          ..write('id: $id, ')
          ..write('routeId: $routeId, ')
          ..write('authorId: $authorId, ')
          ..write('gradeSystem: $gradeSystem, ')
          ..write('gradeRaw: $gradeRaw, ')
          ..write('gradeSortKey: $gradeSortKey, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    routeId,
    authorId,
    gradeSystem,
    gradeRaw,
    gradeSortKey,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GradeOpinionRow &&
          other.id == this.id &&
          other.routeId == this.routeId &&
          other.authorId == this.authorId &&
          other.gradeSystem == this.gradeSystem &&
          other.gradeRaw == this.gradeRaw &&
          other.gradeSortKey == this.gradeSortKey &&
          other.createdAt == this.createdAt);
}

class GradeOpinionRowsCompanion extends UpdateCompanion<GradeOpinionRow> {
  final Value<String> id;
  final Value<String> routeId;
  final Value<String> authorId;
  final Value<String> gradeSystem;
  final Value<String> gradeRaw;
  final Value<double?> gradeSortKey;
  final Value<int> createdAt;
  final Value<int> rowid;
  const GradeOpinionRowsCompanion({
    this.id = const Value.absent(),
    this.routeId = const Value.absent(),
    this.authorId = const Value.absent(),
    this.gradeSystem = const Value.absent(),
    this.gradeRaw = const Value.absent(),
    this.gradeSortKey = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GradeOpinionRowsCompanion.insert({
    required String id,
    required String routeId,
    required String authorId,
    required String gradeSystem,
    required String gradeRaw,
    this.gradeSortKey = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       routeId = Value(routeId),
       authorId = Value(authorId),
       gradeSystem = Value(gradeSystem),
       gradeRaw = Value(gradeRaw),
       createdAt = Value(createdAt);
  static Insertable<GradeOpinionRow> custom({
    Expression<String>? id,
    Expression<String>? routeId,
    Expression<String>? authorId,
    Expression<String>? gradeSystem,
    Expression<String>? gradeRaw,
    Expression<double>? gradeSortKey,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (routeId != null) 'route_id': routeId,
      if (authorId != null) 'author_id': authorId,
      if (gradeSystem != null) 'grade_system': gradeSystem,
      if (gradeRaw != null) 'grade_raw': gradeRaw,
      if (gradeSortKey != null) 'grade_sort_key': gradeSortKey,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GradeOpinionRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? routeId,
    Value<String>? authorId,
    Value<String>? gradeSystem,
    Value<String>? gradeRaw,
    Value<double?>? gradeSortKey,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return GradeOpinionRowsCompanion(
      id: id ?? this.id,
      routeId: routeId ?? this.routeId,
      authorId: authorId ?? this.authorId,
      gradeSystem: gradeSystem ?? this.gradeSystem,
      gradeRaw: gradeRaw ?? this.gradeRaw,
      gradeSortKey: gradeSortKey ?? this.gradeSortKey,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (authorId.present) {
      map['author_id'] = Variable<String>(authorId.value);
    }
    if (gradeSystem.present) {
      map['grade_system'] = Variable<String>(gradeSystem.value);
    }
    if (gradeRaw.present) {
      map['grade_raw'] = Variable<String>(gradeRaw.value);
    }
    if (gradeSortKey.present) {
      map['grade_sort_key'] = Variable<double>(gradeSortKey.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GradeOpinionRowsCompanion(')
          ..write('id: $id, ')
          ..write('routeId: $routeId, ')
          ..write('authorId: $authorId, ')
          ..write('gradeSystem: $gradeSystem, ')
          ..write('gradeRaw: $gradeRaw, ')
          ..write('gradeSortKey: $gradeSortKey, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TopoVerificationRowsTable extends TopoVerificationRows
    with TableInfo<$TopoVerificationRowsTable, TopoVerificationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TopoVerificationRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authorIdMeta = const VerificationMeta(
    'authorId',
  );
  @override
  late final GeneratedColumn<String> authorId = GeneratedColumn<String>(
    'author_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accurateMeta = const VerificationMeta(
    'accurate',
  );
  @override
  late final GeneratedColumn<bool> accurate = GeneratedColumn<bool>(
    'accurate',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("accurate" IN (0, 1))',
    ),
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    wallId,
    authorId,
    accurate,
    note,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'topo_verification_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<TopoVerificationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    } else if (isInserting) {
      context.missing(_wallIdMeta);
    }
    if (data.containsKey('author_id')) {
      context.handle(
        _authorIdMeta,
        authorId.isAcceptableOrUnknown(data['author_id']!, _authorIdMeta),
      );
    } else if (isInserting) {
      context.missing(_authorIdMeta);
    }
    if (data.containsKey('accurate')) {
      context.handle(
        _accurateMeta,
        accurate.isAcceptableOrUnknown(data['accurate']!, _accurateMeta),
      );
    } else if (isInserting) {
      context.missing(_accurateMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TopoVerificationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TopoVerificationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      )!,
      authorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_id'],
      )!,
      accurate: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}accurate'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $TopoVerificationRowsTable createAlias(String alias) {
    return $TopoVerificationRowsTable(attachedDatabase, alias);
  }
}

class TopoVerificationRow extends DataClass
    implements Insertable<TopoVerificationRow> {
  final String id;
  final String wallId;
  final String authorId;

  /// Whether this person says the topo matches the rock.
  final bool accurate;
  final String? note;
  final int createdAt;
  const TopoVerificationRow({
    required this.id,
    required this.wallId,
    required this.authorId,
    required this.accurate,
    this.note,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['wall_id'] = Variable<String>(wallId);
    map['author_id'] = Variable<String>(authorId);
    map['accurate'] = Variable<bool>(accurate);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  TopoVerificationRowsCompanion toCompanion(bool nullToAbsent) {
    return TopoVerificationRowsCompanion(
      id: Value(id),
      wallId: Value(wallId),
      authorId: Value(authorId),
      accurate: Value(accurate),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      createdAt: Value(createdAt),
    );
  }

  factory TopoVerificationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TopoVerificationRow(
      id: serializer.fromJson<String>(json['id']),
      wallId: serializer.fromJson<String>(json['wallId']),
      authorId: serializer.fromJson<String>(json['authorId']),
      accurate: serializer.fromJson<bool>(json['accurate']),
      note: serializer.fromJson<String?>(json['note']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'wallId': serializer.toJson<String>(wallId),
      'authorId': serializer.toJson<String>(authorId),
      'accurate': serializer.toJson<bool>(accurate),
      'note': serializer.toJson<String?>(note),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  TopoVerificationRow copyWith({
    String? id,
    String? wallId,
    String? authorId,
    bool? accurate,
    Value<String?> note = const Value.absent(),
    int? createdAt,
  }) => TopoVerificationRow(
    id: id ?? this.id,
    wallId: wallId ?? this.wallId,
    authorId: authorId ?? this.authorId,
    accurate: accurate ?? this.accurate,
    note: note.present ? note.value : this.note,
    createdAt: createdAt ?? this.createdAt,
  );
  TopoVerificationRow copyWithCompanion(TopoVerificationRowsCompanion data) {
    return TopoVerificationRow(
      id: data.id.present ? data.id.value : this.id,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      authorId: data.authorId.present ? data.authorId.value : this.authorId,
      accurate: data.accurate.present ? data.accurate.value : this.accurate,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TopoVerificationRow(')
          ..write('id: $id, ')
          ..write('wallId: $wallId, ')
          ..write('authorId: $authorId, ')
          ..write('accurate: $accurate, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, wallId, authorId, accurate, note, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TopoVerificationRow &&
          other.id == this.id &&
          other.wallId == this.wallId &&
          other.authorId == this.authorId &&
          other.accurate == this.accurate &&
          other.note == this.note &&
          other.createdAt == this.createdAt);
}

class TopoVerificationRowsCompanion
    extends UpdateCompanion<TopoVerificationRow> {
  final Value<String> id;
  final Value<String> wallId;
  final Value<String> authorId;
  final Value<bool> accurate;
  final Value<String?> note;
  final Value<int> createdAt;
  final Value<int> rowid;
  const TopoVerificationRowsCompanion({
    this.id = const Value.absent(),
    this.wallId = const Value.absent(),
    this.authorId = const Value.absent(),
    this.accurate = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TopoVerificationRowsCompanion.insert({
    required String id,
    required String wallId,
    required String authorId,
    required bool accurate,
    this.note = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       wallId = Value(wallId),
       authorId = Value(authorId),
       accurate = Value(accurate),
       createdAt = Value(createdAt);
  static Insertable<TopoVerificationRow> custom({
    Expression<String>? id,
    Expression<String>? wallId,
    Expression<String>? authorId,
    Expression<bool>? accurate,
    Expression<String>? note,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (wallId != null) 'wall_id': wallId,
      if (authorId != null) 'author_id': authorId,
      if (accurate != null) 'accurate': accurate,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TopoVerificationRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? wallId,
    Value<String>? authorId,
    Value<bool>? accurate,
    Value<String?>? note,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return TopoVerificationRowsCompanion(
      id: id ?? this.id,
      wallId: wallId ?? this.wallId,
      authorId: authorId ?? this.authorId,
      accurate: accurate ?? this.accurate,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (authorId.present) {
      map['author_id'] = Variable<String>(authorId.value);
    }
    if (accurate.present) {
      map['accurate'] = Variable<bool>(accurate.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TopoVerificationRowsCompanion(')
          ..write('id: $id, ')
          ..write('wallId: $wallId, ')
          ..write('authorId: $authorId, ')
          ..write('accurate: $accurate, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TopoHazardRowsTable extends TopoHazardRows
    with TableInfo<$TopoHazardRowsTable, TopoHazardRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TopoHazardRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _routeIdMeta = const VerificationMeta(
    'routeId',
  );
  @override
  late final GeneratedColumn<String> routeId = GeneratedColumn<String>(
    'route_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _authorIdMeta = const VerificationMeta(
    'authorId',
  );
  @override
  late final GeneratedColumn<String> authorId = GeneratedColumn<String>(
    'author_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _severityMeta = const VerificationMeta(
    'severity',
  );
  @override
  late final GeneratedColumn<String> severity = GeneratedColumn<String>(
    'severity',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resolvedAtMeta = const VerificationMeta(
    'resolvedAt',
  );
  @override
  late final GeneratedColumn<int> resolvedAt = GeneratedColumn<int>(
    'resolved_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resolvedByMeta = const VerificationMeta(
    'resolvedBy',
  );
  @override
  late final GeneratedColumn<String> resolvedBy = GeneratedColumn<String>(
    'resolved_by',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    wallId,
    routeId,
    authorId,
    severity,
    body,
    resolvedAt,
    resolvedBy,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'topo_hazard_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<TopoHazardRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    } else if (isInserting) {
      context.missing(_wallIdMeta);
    }
    if (data.containsKey('route_id')) {
      context.handle(
        _routeIdMeta,
        routeId.isAcceptableOrUnknown(data['route_id']!, _routeIdMeta),
      );
    }
    if (data.containsKey('author_id')) {
      context.handle(
        _authorIdMeta,
        authorId.isAcceptableOrUnknown(data['author_id']!, _authorIdMeta),
      );
    } else if (isInserting) {
      context.missing(_authorIdMeta);
    }
    if (data.containsKey('severity')) {
      context.handle(
        _severityMeta,
        severity.isAcceptableOrUnknown(data['severity']!, _severityMeta),
      );
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('resolved_at')) {
      context.handle(
        _resolvedAtMeta,
        resolvedAt.isAcceptableOrUnknown(data['resolved_at']!, _resolvedAtMeta),
      );
    }
    if (data.containsKey('resolved_by')) {
      context.handle(
        _resolvedByMeta,
        resolvedBy.isAcceptableOrUnknown(data['resolved_by']!, _resolvedByMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TopoHazardRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TopoHazardRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      )!,
      routeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_id'],
      ),
      authorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_id'],
      )!,
      severity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}severity'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      resolvedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}resolved_at'],
      ),
      resolvedBy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resolved_by'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $TopoHazardRowsTable createAlias(String alias) {
    return $TopoHazardRowsTable(attachedDatabase, alias);
  }
}

class TopoHazardRow extends DataClass implements Insertable<TopoHazardRow> {
  final String id;
  final String wallId;

  /// `null` for a hazard about the whole topo — the approach, the descent,
  /// the belay — rather than one specific line.
  final String? routeId;
  final String authorId;

  /// `note` | `caution` | `danger`, as the raw server string. Parsed by
  /// `HazardSeverity.fromWire`, which resolves an unknown value to `danger` —
  /// the opposite direction to moderation state, because a safety warning
  /// must fail loud rather than be quietly demoted.
  final String severity;
  final String body;

  /// When somebody marked this dealt with, or null. The report itself is
  /// never deleted by the topo owner — that is the point of the split (C-12).
  final int? resolvedAt;

  /// Who resolved it. The reporter withdrawing their own report and the topo
  /// owner saying it is fixed are very different claims.
  final String? resolvedBy;
  final int createdAt;
  const TopoHazardRow({
    required this.id,
    required this.wallId,
    this.routeId,
    required this.authorId,
    required this.severity,
    required this.body,
    this.resolvedAt,
    this.resolvedBy,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['wall_id'] = Variable<String>(wallId);
    if (!nullToAbsent || routeId != null) {
      map['route_id'] = Variable<String>(routeId);
    }
    map['author_id'] = Variable<String>(authorId);
    map['severity'] = Variable<String>(severity);
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || resolvedAt != null) {
      map['resolved_at'] = Variable<int>(resolvedAt);
    }
    if (!nullToAbsent || resolvedBy != null) {
      map['resolved_by'] = Variable<String>(resolvedBy);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  TopoHazardRowsCompanion toCompanion(bool nullToAbsent) {
    return TopoHazardRowsCompanion(
      id: Value(id),
      wallId: Value(wallId),
      routeId: routeId == null && nullToAbsent
          ? const Value.absent()
          : Value(routeId),
      authorId: Value(authorId),
      severity: Value(severity),
      body: Value(body),
      resolvedAt: resolvedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(resolvedAt),
      resolvedBy: resolvedBy == null && nullToAbsent
          ? const Value.absent()
          : Value(resolvedBy),
      createdAt: Value(createdAt),
    );
  }

  factory TopoHazardRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TopoHazardRow(
      id: serializer.fromJson<String>(json['id']),
      wallId: serializer.fromJson<String>(json['wallId']),
      routeId: serializer.fromJson<String?>(json['routeId']),
      authorId: serializer.fromJson<String>(json['authorId']),
      severity: serializer.fromJson<String>(json['severity']),
      body: serializer.fromJson<String>(json['body']),
      resolvedAt: serializer.fromJson<int?>(json['resolvedAt']),
      resolvedBy: serializer.fromJson<String?>(json['resolvedBy']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'wallId': serializer.toJson<String>(wallId),
      'routeId': serializer.toJson<String?>(routeId),
      'authorId': serializer.toJson<String>(authorId),
      'severity': serializer.toJson<String>(severity),
      'body': serializer.toJson<String>(body),
      'resolvedAt': serializer.toJson<int?>(resolvedAt),
      'resolvedBy': serializer.toJson<String?>(resolvedBy),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  TopoHazardRow copyWith({
    String? id,
    String? wallId,
    Value<String?> routeId = const Value.absent(),
    String? authorId,
    String? severity,
    String? body,
    Value<int?> resolvedAt = const Value.absent(),
    Value<String?> resolvedBy = const Value.absent(),
    int? createdAt,
  }) => TopoHazardRow(
    id: id ?? this.id,
    wallId: wallId ?? this.wallId,
    routeId: routeId.present ? routeId.value : this.routeId,
    authorId: authorId ?? this.authorId,
    severity: severity ?? this.severity,
    body: body ?? this.body,
    resolvedAt: resolvedAt.present ? resolvedAt.value : this.resolvedAt,
    resolvedBy: resolvedBy.present ? resolvedBy.value : this.resolvedBy,
    createdAt: createdAt ?? this.createdAt,
  );
  TopoHazardRow copyWithCompanion(TopoHazardRowsCompanion data) {
    return TopoHazardRow(
      id: data.id.present ? data.id.value : this.id,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      routeId: data.routeId.present ? data.routeId.value : this.routeId,
      authorId: data.authorId.present ? data.authorId.value : this.authorId,
      severity: data.severity.present ? data.severity.value : this.severity,
      body: data.body.present ? data.body.value : this.body,
      resolvedAt: data.resolvedAt.present
          ? data.resolvedAt.value
          : this.resolvedAt,
      resolvedBy: data.resolvedBy.present
          ? data.resolvedBy.value
          : this.resolvedBy,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TopoHazardRow(')
          ..write('id: $id, ')
          ..write('wallId: $wallId, ')
          ..write('routeId: $routeId, ')
          ..write('authorId: $authorId, ')
          ..write('severity: $severity, ')
          ..write('body: $body, ')
          ..write('resolvedAt: $resolvedAt, ')
          ..write('resolvedBy: $resolvedBy, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    wallId,
    routeId,
    authorId,
    severity,
    body,
    resolvedAt,
    resolvedBy,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TopoHazardRow &&
          other.id == this.id &&
          other.wallId == this.wallId &&
          other.routeId == this.routeId &&
          other.authorId == this.authorId &&
          other.severity == this.severity &&
          other.body == this.body &&
          other.resolvedAt == this.resolvedAt &&
          other.resolvedBy == this.resolvedBy &&
          other.createdAt == this.createdAt);
}

class TopoHazardRowsCompanion extends UpdateCompanion<TopoHazardRow> {
  final Value<String> id;
  final Value<String> wallId;
  final Value<String?> routeId;
  final Value<String> authorId;
  final Value<String> severity;
  final Value<String> body;
  final Value<int?> resolvedAt;
  final Value<String?> resolvedBy;
  final Value<int> createdAt;
  final Value<int> rowid;
  const TopoHazardRowsCompanion({
    this.id = const Value.absent(),
    this.wallId = const Value.absent(),
    this.routeId = const Value.absent(),
    this.authorId = const Value.absent(),
    this.severity = const Value.absent(),
    this.body = const Value.absent(),
    this.resolvedAt = const Value.absent(),
    this.resolvedBy = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TopoHazardRowsCompanion.insert({
    required String id,
    required String wallId,
    this.routeId = const Value.absent(),
    required String authorId,
    required String severity,
    required String body,
    this.resolvedAt = const Value.absent(),
    this.resolvedBy = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       wallId = Value(wallId),
       authorId = Value(authorId),
       severity = Value(severity),
       body = Value(body),
       createdAt = Value(createdAt);
  static Insertable<TopoHazardRow> custom({
    Expression<String>? id,
    Expression<String>? wallId,
    Expression<String>? routeId,
    Expression<String>? authorId,
    Expression<String>? severity,
    Expression<String>? body,
    Expression<int>? resolvedAt,
    Expression<String>? resolvedBy,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (wallId != null) 'wall_id': wallId,
      if (routeId != null) 'route_id': routeId,
      if (authorId != null) 'author_id': authorId,
      if (severity != null) 'severity': severity,
      if (body != null) 'body': body,
      if (resolvedAt != null) 'resolved_at': resolvedAt,
      if (resolvedBy != null) 'resolved_by': resolvedBy,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TopoHazardRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? wallId,
    Value<String?>? routeId,
    Value<String>? authorId,
    Value<String>? severity,
    Value<String>? body,
    Value<int?>? resolvedAt,
    Value<String?>? resolvedBy,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return TopoHazardRowsCompanion(
      id: id ?? this.id,
      wallId: wallId ?? this.wallId,
      routeId: routeId ?? this.routeId,
      authorId: authorId ?? this.authorId,
      severity: severity ?? this.severity,
      body: body ?? this.body,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      resolvedBy: resolvedBy ?? this.resolvedBy,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (routeId.present) {
      map['route_id'] = Variable<String>(routeId.value);
    }
    if (authorId.present) {
      map['author_id'] = Variable<String>(authorId.value);
    }
    if (severity.present) {
      map['severity'] = Variable<String>(severity.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (resolvedAt.present) {
      map['resolved_at'] = Variable<int>(resolvedAt.value);
    }
    if (resolvedBy.present) {
      map['resolved_by'] = Variable<String>(resolvedBy.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TopoHazardRowsCompanion(')
          ..write('id: $id, ')
          ..write('wallId: $wallId, ')
          ..write('routeId: $routeId, ')
          ..write('authorId: $authorId, ')
          ..write('severity: $severity, ')
          ..write('body: $body, ')
          ..write('resolvedAt: $resolvedAt, ')
          ..write('resolvedBy: $resolvedBy, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotificationRowsTable extends NotificationRows
    with TableInfo<$NotificationRowsTable, NotificationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotificationRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recipientIdMeta = const VerificationMeta(
    'recipientId',
  );
  @override
  late final GeneratedColumn<String> recipientId = GeneratedColumn<String>(
    'recipient_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actorIdMeta = const VerificationMeta(
    'actorId',
  );
  @override
  late final GeneratedColumn<String> actorId = GeneratedColumn<String>(
    'actor_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wallIdMeta = const VerificationMeta('wallId');
  @override
  late final GeneratedColumn<String> wallId = GeneratedColumn<String>(
    'wall_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ascentIdMeta = const VerificationMeta(
    'ascentId',
  );
  @override
  late final GeneratedColumn<String> ascentId = GeneratedColumn<String>(
    'ascent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _commentIdMeta = const VerificationMeta(
    'commentId',
  );
  @override
  late final GeneratedColumn<String> commentId = GeneratedColumn<String>(
    'comment_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _previewMeta = const VerificationMeta(
    'preview',
  );
  @override
  late final GeneratedColumn<String> preview = GeneratedColumn<String>(
    'preview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _readAtMeta = const VerificationMeta('readAt');
  @override
  late final GeneratedColumn<int> readAt = GeneratedColumn<int>(
    'read_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    recipientId,
    kind,
    actorId,
    wallId,
    ascentId,
    commentId,
    preview,
    createdAt,
    readAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notification_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotificationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('recipient_id')) {
      context.handle(
        _recipientIdMeta,
        recipientId.isAcceptableOrUnknown(
          data['recipient_id']!,
          _recipientIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recipientIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('actor_id')) {
      context.handle(
        _actorIdMeta,
        actorId.isAcceptableOrUnknown(data['actor_id']!, _actorIdMeta),
      );
    }
    if (data.containsKey('wall_id')) {
      context.handle(
        _wallIdMeta,
        wallId.isAcceptableOrUnknown(data['wall_id']!, _wallIdMeta),
      );
    }
    if (data.containsKey('ascent_id')) {
      context.handle(
        _ascentIdMeta,
        ascentId.isAcceptableOrUnknown(data['ascent_id']!, _ascentIdMeta),
      );
    }
    if (data.containsKey('comment_id')) {
      context.handle(
        _commentIdMeta,
        commentId.isAcceptableOrUnknown(data['comment_id']!, _commentIdMeta),
      );
    }
    if (data.containsKey('preview')) {
      context.handle(
        _previewMeta,
        preview.isAcceptableOrUnknown(data['preview']!, _previewMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('read_at')) {
      context.handle(
        _readAtMeta,
        readAt.isAcceptableOrUnknown(data['read_at']!, _readAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NotificationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotificationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      recipientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recipient_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      actorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}actor_id'],
      ),
      wallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wall_id'],
      ),
      ascentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ascent_id'],
      ),
      commentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}comment_id'],
      ),
      preview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}preview'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      readAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read_at'],
      ),
    );
  }

  @override
  $NotificationRowsTable createAlias(String alias) {
    return $NotificationRowsTable(attachedDatabase, alias);
  }
}

class NotificationRow extends DataClass implements Insertable<NotificationRow> {
  final String id;

  /// Who this is FOR. Every read is scoped by it, and the server's RLS scopes
  /// on it too, so a pull can only ever return the signed-in user's own.
  final String recipientId;

  /// What happened, as the raw server string (`comment`, `mention`, `like`,
  /// `suggestion`, …). Stored raw and parsed at the edge so a build that
  /// predates a new kind renders it as a generic entry instead of throwing on
  /// a value its enum has never heard of — the same rule [GradeOpinionRows]
  /// applies to grade systems.
  final String kind;

  /// Who did it. Nullable because not every kind has a person behind it, and
  /// because an actor whose account is gone must not take the notification
  /// with them.
  final String? actorId;

  /// What it happened to. Which of these is set depends on [kind]; all are
  /// nullable so a new kind can arrive without a schema change.
  final String? wallId;
  final String? ascentId;
  final String? commentId;

  /// A short server-rendered summary — e.g. the first line of the comment.
  /// Nullable: an entry is perfectly readable without one.
  final String? preview;
  final int createdAt;

  /// When the user read it, or `null` while unread. A timestamp rather than a
  /// bool so "mark all read" is one write with one value, and so the unread
  /// badge is a plain `readAt IS NULL` count.
  final int? readAt;
  const NotificationRow({
    required this.id,
    required this.recipientId,
    required this.kind,
    this.actorId,
    this.wallId,
    this.ascentId,
    this.commentId,
    this.preview,
    required this.createdAt,
    this.readAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['recipient_id'] = Variable<String>(recipientId);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || actorId != null) {
      map['actor_id'] = Variable<String>(actorId);
    }
    if (!nullToAbsent || wallId != null) {
      map['wall_id'] = Variable<String>(wallId);
    }
    if (!nullToAbsent || ascentId != null) {
      map['ascent_id'] = Variable<String>(ascentId);
    }
    if (!nullToAbsent || commentId != null) {
      map['comment_id'] = Variable<String>(commentId);
    }
    if (!nullToAbsent || preview != null) {
      map['preview'] = Variable<String>(preview);
    }
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || readAt != null) {
      map['read_at'] = Variable<int>(readAt);
    }
    return map;
  }

  NotificationRowsCompanion toCompanion(bool nullToAbsent) {
    return NotificationRowsCompanion(
      id: Value(id),
      recipientId: Value(recipientId),
      kind: Value(kind),
      actorId: actorId == null && nullToAbsent
          ? const Value.absent()
          : Value(actorId),
      wallId: wallId == null && nullToAbsent
          ? const Value.absent()
          : Value(wallId),
      ascentId: ascentId == null && nullToAbsent
          ? const Value.absent()
          : Value(ascentId),
      commentId: commentId == null && nullToAbsent
          ? const Value.absent()
          : Value(commentId),
      preview: preview == null && nullToAbsent
          ? const Value.absent()
          : Value(preview),
      createdAt: Value(createdAt),
      readAt: readAt == null && nullToAbsent
          ? const Value.absent()
          : Value(readAt),
    );
  }

  factory NotificationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotificationRow(
      id: serializer.fromJson<String>(json['id']),
      recipientId: serializer.fromJson<String>(json['recipientId']),
      kind: serializer.fromJson<String>(json['kind']),
      actorId: serializer.fromJson<String?>(json['actorId']),
      wallId: serializer.fromJson<String?>(json['wallId']),
      ascentId: serializer.fromJson<String?>(json['ascentId']),
      commentId: serializer.fromJson<String?>(json['commentId']),
      preview: serializer.fromJson<String?>(json['preview']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      readAt: serializer.fromJson<int?>(json['readAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'recipientId': serializer.toJson<String>(recipientId),
      'kind': serializer.toJson<String>(kind),
      'actorId': serializer.toJson<String?>(actorId),
      'wallId': serializer.toJson<String?>(wallId),
      'ascentId': serializer.toJson<String?>(ascentId),
      'commentId': serializer.toJson<String?>(commentId),
      'preview': serializer.toJson<String?>(preview),
      'createdAt': serializer.toJson<int>(createdAt),
      'readAt': serializer.toJson<int?>(readAt),
    };
  }

  NotificationRow copyWith({
    String? id,
    String? recipientId,
    String? kind,
    Value<String?> actorId = const Value.absent(),
    Value<String?> wallId = const Value.absent(),
    Value<String?> ascentId = const Value.absent(),
    Value<String?> commentId = const Value.absent(),
    Value<String?> preview = const Value.absent(),
    int? createdAt,
    Value<int?> readAt = const Value.absent(),
  }) => NotificationRow(
    id: id ?? this.id,
    recipientId: recipientId ?? this.recipientId,
    kind: kind ?? this.kind,
    actorId: actorId.present ? actorId.value : this.actorId,
    wallId: wallId.present ? wallId.value : this.wallId,
    ascentId: ascentId.present ? ascentId.value : this.ascentId,
    commentId: commentId.present ? commentId.value : this.commentId,
    preview: preview.present ? preview.value : this.preview,
    createdAt: createdAt ?? this.createdAt,
    readAt: readAt.present ? readAt.value : this.readAt,
  );
  NotificationRow copyWithCompanion(NotificationRowsCompanion data) {
    return NotificationRow(
      id: data.id.present ? data.id.value : this.id,
      recipientId: data.recipientId.present
          ? data.recipientId.value
          : this.recipientId,
      kind: data.kind.present ? data.kind.value : this.kind,
      actorId: data.actorId.present ? data.actorId.value : this.actorId,
      wallId: data.wallId.present ? data.wallId.value : this.wallId,
      ascentId: data.ascentId.present ? data.ascentId.value : this.ascentId,
      commentId: data.commentId.present ? data.commentId.value : this.commentId,
      preview: data.preview.present ? data.preview.value : this.preview,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      readAt: data.readAt.present ? data.readAt.value : this.readAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotificationRow(')
          ..write('id: $id, ')
          ..write('recipientId: $recipientId, ')
          ..write('kind: $kind, ')
          ..write('actorId: $actorId, ')
          ..write('wallId: $wallId, ')
          ..write('ascentId: $ascentId, ')
          ..write('commentId: $commentId, ')
          ..write('preview: $preview, ')
          ..write('createdAt: $createdAt, ')
          ..write('readAt: $readAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    recipientId,
    kind,
    actorId,
    wallId,
    ascentId,
    commentId,
    preview,
    createdAt,
    readAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotificationRow &&
          other.id == this.id &&
          other.recipientId == this.recipientId &&
          other.kind == this.kind &&
          other.actorId == this.actorId &&
          other.wallId == this.wallId &&
          other.ascentId == this.ascentId &&
          other.commentId == this.commentId &&
          other.preview == this.preview &&
          other.createdAt == this.createdAt &&
          other.readAt == this.readAt);
}

class NotificationRowsCompanion extends UpdateCompanion<NotificationRow> {
  final Value<String> id;
  final Value<String> recipientId;
  final Value<String> kind;
  final Value<String?> actorId;
  final Value<String?> wallId;
  final Value<String?> ascentId;
  final Value<String?> commentId;
  final Value<String?> preview;
  final Value<int> createdAt;
  final Value<int?> readAt;
  final Value<int> rowid;
  const NotificationRowsCompanion({
    this.id = const Value.absent(),
    this.recipientId = const Value.absent(),
    this.kind = const Value.absent(),
    this.actorId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.ascentId = const Value.absent(),
    this.commentId = const Value.absent(),
    this.preview = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.readAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotificationRowsCompanion.insert({
    required String id,
    required String recipientId,
    required String kind,
    this.actorId = const Value.absent(),
    this.wallId = const Value.absent(),
    this.ascentId = const Value.absent(),
    this.commentId = const Value.absent(),
    this.preview = const Value.absent(),
    required int createdAt,
    this.readAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       recipientId = Value(recipientId),
       kind = Value(kind),
       createdAt = Value(createdAt);
  static Insertable<NotificationRow> custom({
    Expression<String>? id,
    Expression<String>? recipientId,
    Expression<String>? kind,
    Expression<String>? actorId,
    Expression<String>? wallId,
    Expression<String>? ascentId,
    Expression<String>? commentId,
    Expression<String>? preview,
    Expression<int>? createdAt,
    Expression<int>? readAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (recipientId != null) 'recipient_id': recipientId,
      if (kind != null) 'kind': kind,
      if (actorId != null) 'actor_id': actorId,
      if (wallId != null) 'wall_id': wallId,
      if (ascentId != null) 'ascent_id': ascentId,
      if (commentId != null) 'comment_id': commentId,
      if (preview != null) 'preview': preview,
      if (createdAt != null) 'created_at': createdAt,
      if (readAt != null) 'read_at': readAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotificationRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? recipientId,
    Value<String>? kind,
    Value<String?>? actorId,
    Value<String?>? wallId,
    Value<String?>? ascentId,
    Value<String?>? commentId,
    Value<String?>? preview,
    Value<int>? createdAt,
    Value<int?>? readAt,
    Value<int>? rowid,
  }) {
    return NotificationRowsCompanion(
      id: id ?? this.id,
      recipientId: recipientId ?? this.recipientId,
      kind: kind ?? this.kind,
      actorId: actorId ?? this.actorId,
      wallId: wallId ?? this.wallId,
      ascentId: ascentId ?? this.ascentId,
      commentId: commentId ?? this.commentId,
      preview: preview ?? this.preview,
      createdAt: createdAt ?? this.createdAt,
      readAt: readAt ?? this.readAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (recipientId.present) {
      map['recipient_id'] = Variable<String>(recipientId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (actorId.present) {
      map['actor_id'] = Variable<String>(actorId.value);
    }
    if (wallId.present) {
      map['wall_id'] = Variable<String>(wallId.value);
    }
    if (ascentId.present) {
      map['ascent_id'] = Variable<String>(ascentId.value);
    }
    if (commentId.present) {
      map['comment_id'] = Variable<String>(commentId.value);
    }
    if (preview.present) {
      map['preview'] = Variable<String>(preview.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (readAt.present) {
      map['read_at'] = Variable<int>(readAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotificationRowsCompanion(')
          ..write('id: $id, ')
          ..write('recipientId: $recipientId, ')
          ..write('kind: $kind, ')
          ..write('actorId: $actorId, ')
          ..write('wallId: $wallId, ')
          ..write('ascentId: $ascentId, ')
          ..write('commentId: $commentId, ')
          ..write('preview: $preview, ')
          ..write('createdAt: $createdAt, ')
          ..write('readAt: $readAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AreasTable areas = $AreasTable(this);
  late final $SectorsTable sectors = $SectorsTable(this);
  late final $WallsTable walls = $WallsTable(this);
  late final $PhotosTable photos = $PhotosTable(this);
  late final $RoutesTable routes = $RoutesTable(this);
  late final $RouteLinesTable routeLines = $RouteLinesTable(this);
  late final $AscentsTable ascents = $AscentsTable(this);
  late final $CommentsTable comments = $CommentsTable(this);
  late final $LikesTable likes = $LikesTable(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  late final $WallModerationRowsTable wallModerationRows =
      $WallModerationRowsTable(this);
  late final $GradeOpinionRowsTable gradeOpinionRows = $GradeOpinionRowsTable(
    this,
  );
  late final $TopoVerificationRowsTable topoVerificationRows =
      $TopoVerificationRowsTable(this);
  late final $TopoHazardRowsTable topoHazardRows = $TopoHazardRowsTable(this);
  late final $NotificationRowsTable notificationRows = $NotificationRowsTable(
    this,
  );
  late final Index idxSectorsAreaLive = Index(
    'idx_sectors_area_live',
    'CREATE INDEX idx_sectors_area_live ON sectors (area_id) WHERE deleted_at IS NULL',
  );
  late final Index idxWallsSectorLive = Index(
    'idx_walls_sector_live',
    'CREATE INDEX idx_walls_sector_live ON walls (sector_id) WHERE deleted_at IS NULL',
  );
  late final Index idxPhotosWallLive = Index(
    'idx_photos_wall_live',
    'CREATE INDEX idx_photos_wall_live ON photos (wall_id) WHERE deleted_at IS NULL',
  );
  late final Index idxPhotosParentLive = Index(
    'idx_photos_parent_live',
    'CREATE INDEX idx_photos_parent_live ON photos (parent_photo_id) WHERE deleted_at IS NULL',
  );
  late final Index idxRoutesWallNumberLive = Index(
    'idx_routes_wall_number_live',
    'CREATE UNIQUE INDEX idx_routes_wall_number_live ON routes (wall_id, number) WHERE deleted_at IS NULL',
  );
  late final Index idxRoutesPhotoLive = Index(
    'idx_routes_photo_live',
    'CREATE INDEX idx_routes_photo_live ON routes (photo_id) WHERE deleted_at IS NULL',
  );
  late final Index idxRouteLinesRoutePhotoLive = Index(
    'idx_route_lines_route_photo_live',
    'CREATE UNIQUE INDEX idx_route_lines_route_photo_live ON route_lines (route_id, photo_id) WHERE deleted_at IS NULL',
  );
  late final Index idxRouteLinesPhotoLive = Index(
    'idx_route_lines_photo_live',
    'CREATE INDEX idx_route_lines_photo_live ON route_lines (photo_id) WHERE deleted_at IS NULL',
  );
  late final Index idxCommentsWallLive = Index(
    'idx_comments_wall_live',
    'CREATE INDEX idx_comments_wall_live ON comments (wall_id) WHERE deleted_at IS NULL',
  );
  late final Index idxCommentsAscentLive = Index(
    'idx_comments_ascent_live',
    'CREATE INDEX idx_comments_ascent_live ON comments (ascent_id) WHERE deleted_at IS NULL',
  );
  late final Index idxLikesWallLive = Index(
    'idx_likes_wall_live',
    'CREATE INDEX idx_likes_wall_live ON likes (wall_id) WHERE deleted_at IS NULL',
  );
  late final Index idxLikesAscentLive = Index(
    'idx_likes_ascent_live',
    'CREATE INDEX idx_likes_ascent_live ON likes (ascent_id) WHERE deleted_at IS NULL',
  );
  late final Index idxAscentsRouteLive = Index(
    'idx_ascents_route_live',
    'CREATE INDEX idx_ascents_route_live ON ascents (route_id) WHERE deleted_at IS NULL',
  );
  late final Index idxAscentsWallLive = Index(
    'idx_ascents_wall_live',
    'CREATE INDEX idx_ascents_wall_live ON ascents (wall_id) WHERE deleted_at IS NULL',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    areas,
    sectors,
    walls,
    photos,
    routes,
    routeLines,
    ascents,
    comments,
    likes,
    profiles,
    appSettings,
    wallModerationRows,
    gradeOpinionRows,
    topoVerificationRows,
    topoHazardRows,
    notificationRows,
    idxSectorsAreaLive,
    idxWallsSectorLive,
    idxPhotosWallLive,
    idxPhotosParentLive,
    idxRoutesWallNumberLive,
    idxRoutesPhotoLive,
    idxRouteLinesRoutePhotoLive,
    idxRouteLinesPhotoLive,
    idxCommentsWallLive,
    idxCommentsAscentLive,
    idxLikesWallLive,
    idxLikesAscentLive,
    idxAscentsRouteLive,
    idxAscentsWallLive,
  ];
}

typedef $$AreasTableCreateCompanionBuilder =
    AreasCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> accessState,
      Value<String?> accessNote,
      required String name,
      Value<String?> description,
      Value<double?> latitude,
      Value<double?> longitude,
      Value<int> rowid,
    });
typedef $$AreasTableUpdateCompanionBuilder =
    AreasCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> accessState,
      Value<String?> accessNote,
      Value<String> name,
      Value<String?> description,
      Value<double?> latitude,
      Value<double?> longitude,
      Value<int> rowid,
    });

final class $$AreasTableReferences
    extends BaseReferences<_$AppDatabase, $AreasTable, Area> {
  $$AreasTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$SectorsTable, List<Sector>> _sectorsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.sectors,
    aliasName: 'areas__id__sectors__area_id',
  );

  $$SectorsTableProcessedTableManager get sectorsRefs {
    final manager = $$SectorsTableTableManager(
      $_db,
      $_db.sectors,
    ).filter((f) => f.areaId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_sectorsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AreasTableFilterComposer extends Composer<_$AppDatabase, $AreasTable> {
  $$AreasTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get latitude => $composableBuilder(
    column: $table.latitude,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get longitude => $composableBuilder(
    column: $table.longitude,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> sectorsRefs(
    Expression<bool> Function($$SectorsTableFilterComposer f) f,
  ) {
    final $$SectorsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sectors,
      getReferencedColumn: (t) => t.areaId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SectorsTableFilterComposer(
            $db: $db,
            $table: $db.sectors,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AreasTableOrderingComposer
    extends Composer<_$AppDatabase, $AreasTable> {
  $$AreasTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get latitude => $composableBuilder(
    column: $table.latitude,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get longitude => $composableBuilder(
    column: $table.longitude,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AreasTableAnnotationComposer
    extends Composer<_$AppDatabase, $AreasTable> {
  $$AreasTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<double> get latitude =>
      $composableBuilder(column: $table.latitude, builder: (column) => column);

  GeneratedColumn<double> get longitude =>
      $composableBuilder(column: $table.longitude, builder: (column) => column);

  Expression<T> sectorsRefs<T extends Object>(
    Expression<T> Function($$SectorsTableAnnotationComposer a) f,
  ) {
    final $$SectorsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sectors,
      getReferencedColumn: (t) => t.areaId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SectorsTableAnnotationComposer(
            $db: $db,
            $table: $db.sectors,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AreasTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AreasTable,
          Area,
          $$AreasTableFilterComposer,
          $$AreasTableOrderingComposer,
          $$AreasTableAnnotationComposer,
          $$AreasTableCreateCompanionBuilder,
          $$AreasTableUpdateCompanionBuilder,
          (Area, $$AreasTableReferences),
          Area,
          PrefetchHooks Function({bool sectorsRefs})
        > {
  $$AreasTableTableManager(_$AppDatabase db, $AreasTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AreasTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AreasTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AreasTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> accessState = const Value.absent(),
                Value<String?> accessNote = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<double?> latitude = const Value.absent(),
                Value<double?> longitude = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AreasCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                accessState: accessState,
                accessNote: accessNote,
                name: name,
                description: description,
                latitude: latitude,
                longitude: longitude,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> accessState = const Value.absent(),
                Value<String?> accessNote = const Value.absent(),
                required String name,
                Value<String?> description = const Value.absent(),
                Value<double?> latitude = const Value.absent(),
                Value<double?> longitude = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AreasCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                accessState: accessState,
                accessNote: accessNote,
                name: name,
                description: description,
                latitude: latitude,
                longitude: longitude,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$AreasTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({sectorsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (sectorsRefs) db.sectors],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (sectorsRefs)
                    await $_getPrefetchedData<Area, $AreasTable, Sector>(
                      currentTable: table,
                      referencedTable: $$AreasTableReferences._sectorsRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$AreasTableReferences(db, table, p0).sectorsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.areaId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$AreasTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AreasTable,
      Area,
      $$AreasTableFilterComposer,
      $$AreasTableOrderingComposer,
      $$AreasTableAnnotationComposer,
      $$AreasTableCreateCompanionBuilder,
      $$AreasTableUpdateCompanionBuilder,
      (Area, $$AreasTableReferences),
      Area,
      PrefetchHooks Function({bool sectorsRefs})
    >;
typedef $$SectorsTableCreateCompanionBuilder =
    SectorsCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> accessState,
      Value<String?> accessNote,
      required String areaId,
      required String name,
      required int sortOrder,
      Value<int> rowid,
    });
typedef $$SectorsTableUpdateCompanionBuilder =
    SectorsCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> accessState,
      Value<String?> accessNote,
      Value<String> areaId,
      Value<String> name,
      Value<int> sortOrder,
      Value<int> rowid,
    });

final class $$SectorsTableReferences
    extends BaseReferences<_$AppDatabase, $SectorsTable, Sector> {
  $$SectorsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AreasTable _areaIdTable(_$AppDatabase db) =>
      db.areas.createAlias('sectors__area_id__areas__id');

  $$AreasTableProcessedTableManager get areaId {
    final $_column = $_itemColumn<String>('area_id')!;

    final manager = $$AreasTableTableManager(
      $_db,
      $_db.areas,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_areaIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$WallsTable, List<Wall>> _wallsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.walls,
    aliasName: 'sectors__id__walls__sector_id',
  );

  $$WallsTableProcessedTableManager get wallsRefs {
    final manager = $$WallsTableTableManager(
      $_db,
      $_db.walls,
    ).filter((f) => f.sectorId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_wallsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SectorsTableFilterComposer
    extends Composer<_$AppDatabase, $SectorsTable> {
  $$SectorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$AreasTableFilterComposer get areaId {
    final $$AreasTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableFilterComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> wallsRefs(
    Expression<bool> Function($$WallsTableFilterComposer f) f,
  ) {
    final $$WallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.sectorId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableFilterComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SectorsTableOrderingComposer
    extends Composer<_$AppDatabase, $SectorsTable> {
  $$SectorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$AreasTableOrderingComposer get areaId {
    final $$AreasTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableOrderingComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SectorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SectorsTable> {
  $$SectorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$AreasTableAnnotationComposer get areaId {
    final $$AreasTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableAnnotationComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> wallsRefs<T extends Object>(
    Expression<T> Function($$WallsTableAnnotationComposer a) f,
  ) {
    final $$WallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.sectorId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableAnnotationComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SectorsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SectorsTable,
          Sector,
          $$SectorsTableFilterComposer,
          $$SectorsTableOrderingComposer,
          $$SectorsTableAnnotationComposer,
          $$SectorsTableCreateCompanionBuilder,
          $$SectorsTableUpdateCompanionBuilder,
          (Sector, $$SectorsTableReferences),
          Sector,
          PrefetchHooks Function({bool areaId, bool wallsRefs})
        > {
  $$SectorsTableTableManager(_$AppDatabase db, $SectorsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SectorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SectorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SectorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> accessState = const Value.absent(),
                Value<String?> accessNote = const Value.absent(),
                Value<String> areaId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SectorsCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                accessState: accessState,
                accessNote: accessNote,
                areaId: areaId,
                name: name,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> accessState = const Value.absent(),
                Value<String?> accessNote = const Value.absent(),
                required String areaId,
                required String name,
                required int sortOrder,
                Value<int> rowid = const Value.absent(),
              }) => SectorsCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                accessState: accessState,
                accessNote: accessNote,
                areaId: areaId,
                name: name,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SectorsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({areaId = false, wallsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (wallsRefs) db.walls],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (areaId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.areaId,
                                referencedTable: $$SectorsTableReferences
                                    ._areaIdTable(db),
                                referencedColumn: $$SectorsTableReferences
                                    ._areaIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (wallsRefs)
                    await $_getPrefetchedData<Sector, $SectorsTable, Wall>(
                      currentTable: table,
                      referencedTable: $$SectorsTableReferences._wallsRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$SectorsTableReferences(db, table, p0).wallsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.sectorId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SectorsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SectorsTable,
      Sector,
      $$SectorsTableFilterComposer,
      $$SectorsTableOrderingComposer,
      $$SectorsTableAnnotationComposer,
      $$SectorsTableCreateCompanionBuilder,
      $$SectorsTableUpdateCompanionBuilder,
      (Sector, $$SectorsTableReferences),
      Sector,
      PrefetchHooks Function({bool areaId, bool wallsRefs})
    >;
typedef $$WallsTableCreateCompanionBuilder =
    WallsCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> accessState,
      Value<String?> accessNote,
      required String sectorId,
      required String name,
      required int sortOrder,
      Value<String> visibility,
      Value<double?> latitude,
      Value<double?> longitude,
      Value<String?> baselineJson,
      Value<int> rowid,
    });
typedef $$WallsTableUpdateCompanionBuilder =
    WallsCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> accessState,
      Value<String?> accessNote,
      Value<String> sectorId,
      Value<String> name,
      Value<int> sortOrder,
      Value<String> visibility,
      Value<double?> latitude,
      Value<double?> longitude,
      Value<String?> baselineJson,
      Value<int> rowid,
    });

final class $$WallsTableReferences
    extends BaseReferences<_$AppDatabase, $WallsTable, Wall> {
  $$WallsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SectorsTable _sectorIdTable(_$AppDatabase db) =>
      db.sectors.createAlias('walls__sector_id__sectors__id');

  $$SectorsTableProcessedTableManager get sectorId {
    final $_column = $_itemColumn<String>('sector_id')!;

    final manager = $$SectorsTableTableManager(
      $_db,
      $_db.sectors,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sectorIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$PhotosTable, List<Photo>> _photosRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.photos,
    aliasName: 'walls__id__photos__wall_id',
  );

  $$PhotosTableProcessedTableManager get photosRefs {
    final manager = $$PhotosTableTableManager(
      $_db,
      $_db.photos,
    ).filter((f) => f.wallId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_photosRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RoutesTable, List<Route>> _routesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.routes,
    aliasName: 'walls__id__routes__wall_id',
  );

  $$RoutesTableProcessedTableManager get routesRefs {
    final manager = $$RoutesTableTableManager(
      $_db,
      $_db.routes,
    ).filter((f) => f.wallId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_routesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$AscentsTable, List<Ascent>> _ascentsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.ascents,
    aliasName: 'walls__id__ascents__wall_id',
  );

  $$AscentsTableProcessedTableManager get ascentsRefs {
    final manager = $$AscentsTableTableManager(
      $_db,
      $_db.ascents,
    ).filter((f) => f.wallId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_ascentsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CommentsTable, List<Comment>> _commentsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.comments,
    aliasName: 'walls__id__comments__wall_id',
  );

  $$CommentsTableProcessedTableManager get commentsRefs {
    final manager = $$CommentsTableTableManager(
      $_db,
      $_db.comments,
    ).filter((f) => f.wallId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_commentsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LikesTable, List<Like>> _likesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.likes,
    aliasName: 'walls__id__likes__wall_id',
  );

  $$LikesTableProcessedTableManager get likesRefs {
    final manager = $$LikesTableTableManager(
      $_db,
      $_db.likes,
    ).filter((f) => f.wallId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_likesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$WallsTableFilterComposer extends Composer<_$AppDatabase, $WallsTable> {
  $$WallsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get latitude => $composableBuilder(
    column: $table.latitude,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get longitude => $composableBuilder(
    column: $table.longitude,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baselineJson => $composableBuilder(
    column: $table.baselineJson,
    builder: (column) => ColumnFilters(column),
  );

  $$SectorsTableFilterComposer get sectorId {
    final $$SectorsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sectorId,
      referencedTable: $db.sectors,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SectorsTableFilterComposer(
            $db: $db,
            $table: $db.sectors,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> photosRefs(
    Expression<bool> Function($$PhotosTableFilterComposer f) f,
  ) {
    final $$PhotosTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableFilterComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> routesRefs(
    Expression<bool> Function($$RoutesTableFilterComposer f) f,
  ) {
    final $$RoutesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableFilterComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> ascentsRefs(
    Expression<bool> Function($$AscentsTableFilterComposer f) f,
  ) {
    final $$AscentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableFilterComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> commentsRefs(
    Expression<bool> Function($$CommentsTableFilterComposer f) f,
  ) {
    final $$CommentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.comments,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CommentsTableFilterComposer(
            $db: $db,
            $table: $db.comments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> likesRefs(
    Expression<bool> Function($$LikesTableFilterComposer f) f,
  ) {
    final $$LikesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.likes,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LikesTableFilterComposer(
            $db: $db,
            $table: $db.likes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$WallsTableOrderingComposer
    extends Composer<_$AppDatabase, $WallsTable> {
  $$WallsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get latitude => $composableBuilder(
    column: $table.latitude,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get longitude => $composableBuilder(
    column: $table.longitude,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baselineJson => $composableBuilder(
    column: $table.baselineJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$SectorsTableOrderingComposer get sectorId {
    final $$SectorsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sectorId,
      referencedTable: $db.sectors,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SectorsTableOrderingComposer(
            $db: $db,
            $table: $db.sectors,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$WallsTableAnnotationComposer
    extends Composer<_$AppDatabase, $WallsTable> {
  $$WallsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get accessState => $composableBuilder(
    column: $table.accessState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accessNote => $composableBuilder(
    column: $table.accessNote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => column,
  );

  GeneratedColumn<double> get latitude =>
      $composableBuilder(column: $table.latitude, builder: (column) => column);

  GeneratedColumn<double> get longitude =>
      $composableBuilder(column: $table.longitude, builder: (column) => column);

  GeneratedColumn<String> get baselineJson => $composableBuilder(
    column: $table.baselineJson,
    builder: (column) => column,
  );

  $$SectorsTableAnnotationComposer get sectorId {
    final $$SectorsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sectorId,
      referencedTable: $db.sectors,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SectorsTableAnnotationComposer(
            $db: $db,
            $table: $db.sectors,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> photosRefs<T extends Object>(
    Expression<T> Function($$PhotosTableAnnotationComposer a) f,
  ) {
    final $$PhotosTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableAnnotationComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> routesRefs<T extends Object>(
    Expression<T> Function($$RoutesTableAnnotationComposer a) f,
  ) {
    final $$RoutesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableAnnotationComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> ascentsRefs<T extends Object>(
    Expression<T> Function($$AscentsTableAnnotationComposer a) f,
  ) {
    final $$AscentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableAnnotationComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> commentsRefs<T extends Object>(
    Expression<T> Function($$CommentsTableAnnotationComposer a) f,
  ) {
    final $$CommentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.comments,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CommentsTableAnnotationComposer(
            $db: $db,
            $table: $db.comments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> likesRefs<T extends Object>(
    Expression<T> Function($$LikesTableAnnotationComposer a) f,
  ) {
    final $$LikesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.likes,
      getReferencedColumn: (t) => t.wallId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LikesTableAnnotationComposer(
            $db: $db,
            $table: $db.likes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$WallsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WallsTable,
          Wall,
          $$WallsTableFilterComposer,
          $$WallsTableOrderingComposer,
          $$WallsTableAnnotationComposer,
          $$WallsTableCreateCompanionBuilder,
          $$WallsTableUpdateCompanionBuilder,
          (Wall, $$WallsTableReferences),
          Wall,
          PrefetchHooks Function({
            bool sectorId,
            bool photosRefs,
            bool routesRefs,
            bool ascentsRefs,
            bool commentsRefs,
            bool likesRefs,
          })
        > {
  $$WallsTableTableManager(_$AppDatabase db, $WallsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WallsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WallsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WallsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> accessState = const Value.absent(),
                Value<String?> accessNote = const Value.absent(),
                Value<String> sectorId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String> visibility = const Value.absent(),
                Value<double?> latitude = const Value.absent(),
                Value<double?> longitude = const Value.absent(),
                Value<String?> baselineJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WallsCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                accessState: accessState,
                accessNote: accessNote,
                sectorId: sectorId,
                name: name,
                sortOrder: sortOrder,
                visibility: visibility,
                latitude: latitude,
                longitude: longitude,
                baselineJson: baselineJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> accessState = const Value.absent(),
                Value<String?> accessNote = const Value.absent(),
                required String sectorId,
                required String name,
                required int sortOrder,
                Value<String> visibility = const Value.absent(),
                Value<double?> latitude = const Value.absent(),
                Value<double?> longitude = const Value.absent(),
                Value<String?> baselineJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WallsCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                accessState: accessState,
                accessNote: accessNote,
                sectorId: sectorId,
                name: name,
                sortOrder: sortOrder,
                visibility: visibility,
                latitude: latitude,
                longitude: longitude,
                baselineJson: baselineJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$WallsTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                sectorId = false,
                photosRefs = false,
                routesRefs = false,
                ascentsRefs = false,
                commentsRefs = false,
                likesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (photosRefs) db.photos,
                    if (routesRefs) db.routes,
                    if (ascentsRefs) db.ascents,
                    if (commentsRefs) db.comments,
                    if (likesRefs) db.likes,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (sectorId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.sectorId,
                                    referencedTable: $$WallsTableReferences
                                        ._sectorIdTable(db),
                                    referencedColumn: $$WallsTableReferences
                                        ._sectorIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (photosRefs)
                        await $_getPrefetchedData<Wall, $WallsTable, Photo>(
                          currentTable: table,
                          referencedTable: $$WallsTableReferences
                              ._photosRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WallsTableReferences(db, table, p0).photosRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.wallId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (routesRefs)
                        await $_getPrefetchedData<Wall, $WallsTable, Route>(
                          currentTable: table,
                          referencedTable: $$WallsTableReferences
                              ._routesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WallsTableReferences(db, table, p0).routesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.wallId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (ascentsRefs)
                        await $_getPrefetchedData<Wall, $WallsTable, Ascent>(
                          currentTable: table,
                          referencedTable: $$WallsTableReferences
                              ._ascentsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WallsTableReferences(db, table, p0).ascentsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.wallId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (commentsRefs)
                        await $_getPrefetchedData<Wall, $WallsTable, Comment>(
                          currentTable: table,
                          referencedTable: $$WallsTableReferences
                              ._commentsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WallsTableReferences(
                                db,
                                table,
                                p0,
                              ).commentsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.wallId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (likesRefs)
                        await $_getPrefetchedData<Wall, $WallsTable, Like>(
                          currentTable: table,
                          referencedTable: $$WallsTableReferences
                              ._likesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WallsTableReferences(db, table, p0).likesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.wallId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$WallsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WallsTable,
      Wall,
      $$WallsTableFilterComposer,
      $$WallsTableOrderingComposer,
      $$WallsTableAnnotationComposer,
      $$WallsTableCreateCompanionBuilder,
      $$WallsTableUpdateCompanionBuilder,
      (Wall, $$WallsTableReferences),
      Wall,
      PrefetchHooks Function({
        bool sectorId,
        bool photosRefs,
        bool routesRefs,
        bool ascentsRefs,
        bool commentsRefs,
        bool likesRefs,
      })
    >;
typedef $$PhotosTableCreateCompanionBuilder =
    PhotosCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      required String wallId,
      required String localPath,
      required String kind,
      required int width,
      required int height,
      Value<String?> parentPhotoId,
      Value<double?> cropXpct,
      Value<double?> cropWidthPct,
      Value<int> sortOrder,
      Value<bool> isPrimary,
      Value<double?> captureLatitude,
      Value<double?> captureLongitude,
      Value<double?> captureAccuracyMeters,
      Value<double?> captureBearingDegrees,
      Value<double?> layoutPinnedT,
      Value<int> rowid,
    });
typedef $$PhotosTableUpdateCompanionBuilder =
    PhotosCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String> wallId,
      Value<String> localPath,
      Value<String> kind,
      Value<int> width,
      Value<int> height,
      Value<String?> parentPhotoId,
      Value<double?> cropXpct,
      Value<double?> cropWidthPct,
      Value<int> sortOrder,
      Value<bool> isPrimary,
      Value<double?> captureLatitude,
      Value<double?> captureLongitude,
      Value<double?> captureAccuracyMeters,
      Value<double?> captureBearingDegrees,
      Value<double?> layoutPinnedT,
      Value<int> rowid,
    });

final class $$PhotosTableReferences
    extends BaseReferences<_$AppDatabase, $PhotosTable, Photo> {
  $$PhotosTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $WallsTable _wallIdTable(_$AppDatabase db) =>
      db.walls.createAlias('photos__wall_id__walls__id');

  $$WallsTableProcessedTableManager get wallId {
    final $_column = $_itemColumn<String>('wall_id')!;

    final manager = $$WallsTableTableManager(
      $_db,
      $_db.walls,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_wallIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PhotosTable _parentPhotoIdTable(_$AppDatabase db) =>
      db.photos.createAlias('photos__parent_photo_id__photos__id');

  $$PhotosTableProcessedTableManager? get parentPhotoId {
    final $_column = $_itemColumn<String>('parent_photo_id');
    if ($_column == null) return null;
    final manager = $$PhotosTableTableManager(
      $_db,
      $_db.photos,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_parentPhotoIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$RoutesTable, List<Route>> _routesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.routes,
    aliasName: 'photos__id__routes__photo_id',
  );

  $$RoutesTableProcessedTableManager get routesRefs {
    final manager = $$RoutesTableTableManager(
      $_db,
      $_db.routes,
    ).filter((f) => f.photoId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_routesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RouteLinesTable, List<RouteLine>>
  _routeLinesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.routeLines,
    aliasName: 'photos__id__route_lines__photo_id',
  );

  $$RouteLinesTableProcessedTableManager get routeLinesRefs {
    final manager = $$RouteLinesTableTableManager(
      $_db,
      $_db.routeLines,
    ).filter((f) => f.photoId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_routeLinesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PhotosTableFilterComposer
    extends Composer<_$AppDatabase, $PhotosTable> {
  $$PhotosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cropXpct => $composableBuilder(
    column: $table.cropXpct,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cropWidthPct => $composableBuilder(
    column: $table.cropWidthPct,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPrimary => $composableBuilder(
    column: $table.isPrimary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get captureLatitude => $composableBuilder(
    column: $table.captureLatitude,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get captureLongitude => $composableBuilder(
    column: $table.captureLongitude,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get captureAccuracyMeters => $composableBuilder(
    column: $table.captureAccuracyMeters,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get captureBearingDegrees => $composableBuilder(
    column: $table.captureBearingDegrees,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get layoutPinnedT => $composableBuilder(
    column: $table.layoutPinnedT,
    builder: (column) => ColumnFilters(column),
  );

  $$WallsTableFilterComposer get wallId {
    final $$WallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableFilterComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableFilterComposer get parentPhotoId {
    final $$PhotosTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentPhotoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableFilterComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> routesRefs(
    Expression<bool> Function($$RoutesTableFilterComposer f) f,
  ) {
    final $$RoutesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.photoId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableFilterComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> routeLinesRefs(
    Expression<bool> Function($$RouteLinesTableFilterComposer f) f,
  ) {
    final $$RouteLinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routeLines,
      getReferencedColumn: (t) => t.photoId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RouteLinesTableFilterComposer(
            $db: $db,
            $table: $db.routeLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PhotosTableOrderingComposer
    extends Composer<_$AppDatabase, $PhotosTable> {
  $$PhotosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cropXpct => $composableBuilder(
    column: $table.cropXpct,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cropWidthPct => $composableBuilder(
    column: $table.cropWidthPct,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPrimary => $composableBuilder(
    column: $table.isPrimary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get captureLatitude => $composableBuilder(
    column: $table.captureLatitude,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get captureLongitude => $composableBuilder(
    column: $table.captureLongitude,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get captureAccuracyMeters => $composableBuilder(
    column: $table.captureAccuracyMeters,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get captureBearingDegrees => $composableBuilder(
    column: $table.captureBearingDegrees,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get layoutPinnedT => $composableBuilder(
    column: $table.layoutPinnedT,
    builder: (column) => ColumnOrderings(column),
  );

  $$WallsTableOrderingComposer get wallId {
    final $$WallsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableOrderingComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableOrderingComposer get parentPhotoId {
    final $$PhotosTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentPhotoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableOrderingComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PhotosTableAnnotationComposer
    extends Composer<_$AppDatabase, $PhotosTable> {
  $$PhotosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<double> get cropXpct =>
      $composableBuilder(column: $table.cropXpct, builder: (column) => column);

  GeneratedColumn<double> get cropWidthPct => $composableBuilder(
    column: $table.cropWidthPct,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<bool> get isPrimary =>
      $composableBuilder(column: $table.isPrimary, builder: (column) => column);

  GeneratedColumn<double> get captureLatitude => $composableBuilder(
    column: $table.captureLatitude,
    builder: (column) => column,
  );

  GeneratedColumn<double> get captureLongitude => $composableBuilder(
    column: $table.captureLongitude,
    builder: (column) => column,
  );

  GeneratedColumn<double> get captureAccuracyMeters => $composableBuilder(
    column: $table.captureAccuracyMeters,
    builder: (column) => column,
  );

  GeneratedColumn<double> get captureBearingDegrees => $composableBuilder(
    column: $table.captureBearingDegrees,
    builder: (column) => column,
  );

  GeneratedColumn<double> get layoutPinnedT => $composableBuilder(
    column: $table.layoutPinnedT,
    builder: (column) => column,
  );

  $$WallsTableAnnotationComposer get wallId {
    final $$WallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableAnnotationComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableAnnotationComposer get parentPhotoId {
    final $$PhotosTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentPhotoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableAnnotationComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> routesRefs<T extends Object>(
    Expression<T> Function($$RoutesTableAnnotationComposer a) f,
  ) {
    final $$RoutesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.photoId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableAnnotationComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> routeLinesRefs<T extends Object>(
    Expression<T> Function($$RouteLinesTableAnnotationComposer a) f,
  ) {
    final $$RouteLinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routeLines,
      getReferencedColumn: (t) => t.photoId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RouteLinesTableAnnotationComposer(
            $db: $db,
            $table: $db.routeLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PhotosTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PhotosTable,
          Photo,
          $$PhotosTableFilterComposer,
          $$PhotosTableOrderingComposer,
          $$PhotosTableAnnotationComposer,
          $$PhotosTableCreateCompanionBuilder,
          $$PhotosTableUpdateCompanionBuilder,
          (Photo, $$PhotosTableReferences),
          Photo,
          PrefetchHooks Function({
            bool wallId,
            bool parentPhotoId,
            bool routesRefs,
            bool routeLinesRefs,
          })
        > {
  $$PhotosTableTableManager(_$AppDatabase db, $PhotosTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PhotosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PhotosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PhotosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String> wallId = const Value.absent(),
                Value<String> localPath = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int> width = const Value.absent(),
                Value<int> height = const Value.absent(),
                Value<String?> parentPhotoId = const Value.absent(),
                Value<double?> cropXpct = const Value.absent(),
                Value<double?> cropWidthPct = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> isPrimary = const Value.absent(),
                Value<double?> captureLatitude = const Value.absent(),
                Value<double?> captureLongitude = const Value.absent(),
                Value<double?> captureAccuracyMeters = const Value.absent(),
                Value<double?> captureBearingDegrees = const Value.absent(),
                Value<double?> layoutPinnedT = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PhotosCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                localPath: localPath,
                kind: kind,
                width: width,
                height: height,
                parentPhotoId: parentPhotoId,
                cropXpct: cropXpct,
                cropWidthPct: cropWidthPct,
                sortOrder: sortOrder,
                isPrimary: isPrimary,
                captureLatitude: captureLatitude,
                captureLongitude: captureLongitude,
                captureAccuracyMeters: captureAccuracyMeters,
                captureBearingDegrees: captureBearingDegrees,
                layoutPinnedT: layoutPinnedT,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                required String wallId,
                required String localPath,
                required String kind,
                required int width,
                required int height,
                Value<String?> parentPhotoId = const Value.absent(),
                Value<double?> cropXpct = const Value.absent(),
                Value<double?> cropWidthPct = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> isPrimary = const Value.absent(),
                Value<double?> captureLatitude = const Value.absent(),
                Value<double?> captureLongitude = const Value.absent(),
                Value<double?> captureAccuracyMeters = const Value.absent(),
                Value<double?> captureBearingDegrees = const Value.absent(),
                Value<double?> layoutPinnedT = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PhotosCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                localPath: localPath,
                kind: kind,
                width: width,
                height: height,
                parentPhotoId: parentPhotoId,
                cropXpct: cropXpct,
                cropWidthPct: cropWidthPct,
                sortOrder: sortOrder,
                isPrimary: isPrimary,
                captureLatitude: captureLatitude,
                captureLongitude: captureLongitude,
                captureAccuracyMeters: captureAccuracyMeters,
                captureBearingDegrees: captureBearingDegrees,
                layoutPinnedT: layoutPinnedT,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$PhotosTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                wallId = false,
                parentPhotoId = false,
                routesRefs = false,
                routeLinesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (routesRefs) db.routes,
                    if (routeLinesRefs) db.routeLines,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (wallId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.wallId,
                                    referencedTable: $$PhotosTableReferences
                                        ._wallIdTable(db),
                                    referencedColumn: $$PhotosTableReferences
                                        ._wallIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (parentPhotoId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.parentPhotoId,
                                    referencedTable: $$PhotosTableReferences
                                        ._parentPhotoIdTable(db),
                                    referencedColumn: $$PhotosTableReferences
                                        ._parentPhotoIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (routesRefs)
                        await $_getPrefetchedData<Photo, $PhotosTable, Route>(
                          currentTable: table,
                          referencedTable: $$PhotosTableReferences
                              ._routesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PhotosTableReferences(db, table, p0).routesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.photoId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (routeLinesRefs)
                        await $_getPrefetchedData<
                          Photo,
                          $PhotosTable,
                          RouteLine
                        >(
                          currentTable: table,
                          referencedTable: $$PhotosTableReferences
                              ._routeLinesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PhotosTableReferences(
                                db,
                                table,
                                p0,
                              ).routeLinesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.photoId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$PhotosTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PhotosTable,
      Photo,
      $$PhotosTableFilterComposer,
      $$PhotosTableOrderingComposer,
      $$PhotosTableAnnotationComposer,
      $$PhotosTableCreateCompanionBuilder,
      $$PhotosTableUpdateCompanionBuilder,
      (Photo, $$PhotosTableReferences),
      Photo,
      PrefetchHooks Function({
        bool wallId,
        bool parentPhotoId,
        bool routesRefs,
        bool routeLinesRefs,
      })
    >;
typedef $$RoutesTableCreateCompanionBuilder =
    RoutesCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      required String wallId,
      required String photoId,
      required int number,
      Value<String?> name,
      Value<String?> gradeSystem,
      Value<String?> gradeRaw,
      Value<double?> gradeSortKey,
      Value<String?> style,
      Value<String?> description,
      required int colorIndex,
      required String pointsJson,
      required String symbolsJson,
      required int sortOrder,
      Value<bool> visible,
      Value<String?> betaVideoUrl,
      Value<String?> styleTagsJson,
      Value<int?> stars,
      Value<int> rowid,
    });
typedef $$RoutesTableUpdateCompanionBuilder =
    RoutesCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String> wallId,
      Value<String> photoId,
      Value<int> number,
      Value<String?> name,
      Value<String?> gradeSystem,
      Value<String?> gradeRaw,
      Value<double?> gradeSortKey,
      Value<String?> style,
      Value<String?> description,
      Value<int> colorIndex,
      Value<String> pointsJson,
      Value<String> symbolsJson,
      Value<int> sortOrder,
      Value<bool> visible,
      Value<String?> betaVideoUrl,
      Value<String?> styleTagsJson,
      Value<int?> stars,
      Value<int> rowid,
    });

final class $$RoutesTableReferences
    extends BaseReferences<_$AppDatabase, $RoutesTable, Route> {
  $$RoutesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $WallsTable _wallIdTable(_$AppDatabase db) =>
      db.walls.createAlias('routes__wall_id__walls__id');

  $$WallsTableProcessedTableManager get wallId {
    final $_column = $_itemColumn<String>('wall_id')!;

    final manager = $$WallsTableTableManager(
      $_db,
      $_db.walls,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_wallIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PhotosTable _photoIdTable(_$AppDatabase db) =>
      db.photos.createAlias('routes__photo_id__photos__id');

  $$PhotosTableProcessedTableManager get photoId {
    final $_column = $_itemColumn<String>('photo_id')!;

    final manager = $$PhotosTableTableManager(
      $_db,
      $_db.photos,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_photoIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$RouteLinesTable, List<RouteLine>>
  _routeLinesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.routeLines,
    aliasName: 'routes__id__route_lines__route_id',
  );

  $$RouteLinesTableProcessedTableManager get routeLinesRefs {
    final manager = $$RouteLinesTableTableManager(
      $_db,
      $_db.routeLines,
    ).filter((f) => f.routeId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_routeLinesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$AscentsTable, List<Ascent>> _ascentsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.ascents,
    aliasName: 'routes__id__ascents__route_id',
  );

  $$AscentsTableProcessedTableManager get ascentsRefs {
    final manager = $$AscentsTableTableManager(
      $_db,
      $_db.ascents,
    ).filter((f) => f.routeId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_ascentsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$RoutesTableFilterComposer
    extends Composer<_$AppDatabase, $RoutesTable> {
  $$RoutesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get number => $composableBuilder(
    column: $table.number,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gradeSystem => $composableBuilder(
    column: $table.gradeSystem,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gradeRaw => $composableBuilder(
    column: $table.gradeRaw,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get gradeSortKey => $composableBuilder(
    column: $table.gradeSortKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get style => $composableBuilder(
    column: $table.style,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorIndex => $composableBuilder(
    column: $table.colorIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get symbolsJson => $composableBuilder(
    column: $table.symbolsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get visible => $composableBuilder(
    column: $table.visible,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get betaVideoUrl => $composableBuilder(
    column: $table.betaVideoUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get styleTagsJson => $composableBuilder(
    column: $table.styleTagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stars => $composableBuilder(
    column: $table.stars,
    builder: (column) => ColumnFilters(column),
  );

  $$WallsTableFilterComposer get wallId {
    final $$WallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableFilterComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableFilterComposer get photoId {
    final $$PhotosTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.photoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableFilterComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> routeLinesRefs(
    Expression<bool> Function($$RouteLinesTableFilterComposer f) f,
  ) {
    final $$RouteLinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routeLines,
      getReferencedColumn: (t) => t.routeId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RouteLinesTableFilterComposer(
            $db: $db,
            $table: $db.routeLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> ascentsRefs(
    Expression<bool> Function($$AscentsTableFilterComposer f) f,
  ) {
    final $$AscentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.routeId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableFilterComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RoutesTableOrderingComposer
    extends Composer<_$AppDatabase, $RoutesTable> {
  $$RoutesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get number => $composableBuilder(
    column: $table.number,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gradeSystem => $composableBuilder(
    column: $table.gradeSystem,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gradeRaw => $composableBuilder(
    column: $table.gradeRaw,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get gradeSortKey => $composableBuilder(
    column: $table.gradeSortKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get style => $composableBuilder(
    column: $table.style,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorIndex => $composableBuilder(
    column: $table.colorIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get symbolsJson => $composableBuilder(
    column: $table.symbolsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get visible => $composableBuilder(
    column: $table.visible,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get betaVideoUrl => $composableBuilder(
    column: $table.betaVideoUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get styleTagsJson => $composableBuilder(
    column: $table.styleTagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stars => $composableBuilder(
    column: $table.stars,
    builder: (column) => ColumnOrderings(column),
  );

  $$WallsTableOrderingComposer get wallId {
    final $$WallsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableOrderingComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableOrderingComposer get photoId {
    final $$PhotosTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.photoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableOrderingComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RoutesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RoutesTable> {
  $$RoutesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<int> get number =>
      $composableBuilder(column: $table.number, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get gradeSystem => $composableBuilder(
    column: $table.gradeSystem,
    builder: (column) => column,
  );

  GeneratedColumn<String> get gradeRaw =>
      $composableBuilder(column: $table.gradeRaw, builder: (column) => column);

  GeneratedColumn<double> get gradeSortKey => $composableBuilder(
    column: $table.gradeSortKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get style =>
      $composableBuilder(column: $table.style, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<int> get colorIndex => $composableBuilder(
    column: $table.colorIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get symbolsJson => $composableBuilder(
    column: $table.symbolsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<bool> get visible =>
      $composableBuilder(column: $table.visible, builder: (column) => column);

  GeneratedColumn<String> get betaVideoUrl => $composableBuilder(
    column: $table.betaVideoUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get styleTagsJson => $composableBuilder(
    column: $table.styleTagsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get stars =>
      $composableBuilder(column: $table.stars, builder: (column) => column);

  $$WallsTableAnnotationComposer get wallId {
    final $$WallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableAnnotationComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableAnnotationComposer get photoId {
    final $$PhotosTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.photoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableAnnotationComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> routeLinesRefs<T extends Object>(
    Expression<T> Function($$RouteLinesTableAnnotationComposer a) f,
  ) {
    final $$RouteLinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.routeLines,
      getReferencedColumn: (t) => t.routeId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RouteLinesTableAnnotationComposer(
            $db: $db,
            $table: $db.routeLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> ascentsRefs<T extends Object>(
    Expression<T> Function($$AscentsTableAnnotationComposer a) f,
  ) {
    final $$AscentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.routeId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableAnnotationComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RoutesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RoutesTable,
          Route,
          $$RoutesTableFilterComposer,
          $$RoutesTableOrderingComposer,
          $$RoutesTableAnnotationComposer,
          $$RoutesTableCreateCompanionBuilder,
          $$RoutesTableUpdateCompanionBuilder,
          (Route, $$RoutesTableReferences),
          Route,
          PrefetchHooks Function({
            bool wallId,
            bool photoId,
            bool routeLinesRefs,
            bool ascentsRefs,
          })
        > {
  $$RoutesTableTableManager(_$AppDatabase db, $RoutesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RoutesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RoutesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RoutesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String> wallId = const Value.absent(),
                Value<String> photoId = const Value.absent(),
                Value<int> number = const Value.absent(),
                Value<String?> name = const Value.absent(),
                Value<String?> gradeSystem = const Value.absent(),
                Value<String?> gradeRaw = const Value.absent(),
                Value<double?> gradeSortKey = const Value.absent(),
                Value<String?> style = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<int> colorIndex = const Value.absent(),
                Value<String> pointsJson = const Value.absent(),
                Value<String> symbolsJson = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> visible = const Value.absent(),
                Value<String?> betaVideoUrl = const Value.absent(),
                Value<String?> styleTagsJson = const Value.absent(),
                Value<int?> stars = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoutesCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                photoId: photoId,
                number: number,
                name: name,
                gradeSystem: gradeSystem,
                gradeRaw: gradeRaw,
                gradeSortKey: gradeSortKey,
                style: style,
                description: description,
                colorIndex: colorIndex,
                pointsJson: pointsJson,
                symbolsJson: symbolsJson,
                sortOrder: sortOrder,
                visible: visible,
                betaVideoUrl: betaVideoUrl,
                styleTagsJson: styleTagsJson,
                stars: stars,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                required String wallId,
                required String photoId,
                required int number,
                Value<String?> name = const Value.absent(),
                Value<String?> gradeSystem = const Value.absent(),
                Value<String?> gradeRaw = const Value.absent(),
                Value<double?> gradeSortKey = const Value.absent(),
                Value<String?> style = const Value.absent(),
                Value<String?> description = const Value.absent(),
                required int colorIndex,
                required String pointsJson,
                required String symbolsJson,
                required int sortOrder,
                Value<bool> visible = const Value.absent(),
                Value<String?> betaVideoUrl = const Value.absent(),
                Value<String?> styleTagsJson = const Value.absent(),
                Value<int?> stars = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoutesCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                photoId: photoId,
                number: number,
                name: name,
                gradeSystem: gradeSystem,
                gradeRaw: gradeRaw,
                gradeSortKey: gradeSortKey,
                style: style,
                description: description,
                colorIndex: colorIndex,
                pointsJson: pointsJson,
                symbolsJson: symbolsJson,
                sortOrder: sortOrder,
                visible: visible,
                betaVideoUrl: betaVideoUrl,
                styleTagsJson: styleTagsJson,
                stars: stars,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$RoutesTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                wallId = false,
                photoId = false,
                routeLinesRefs = false,
                ascentsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (routeLinesRefs) db.routeLines,
                    if (ascentsRefs) db.ascents,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (wallId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.wallId,
                                    referencedTable: $$RoutesTableReferences
                                        ._wallIdTable(db),
                                    referencedColumn: $$RoutesTableReferences
                                        ._wallIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (photoId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.photoId,
                                    referencedTable: $$RoutesTableReferences
                                        ._photoIdTable(db),
                                    referencedColumn: $$RoutesTableReferences
                                        ._photoIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (routeLinesRefs)
                        await $_getPrefetchedData<
                          Route,
                          $RoutesTable,
                          RouteLine
                        >(
                          currentTable: table,
                          referencedTable: $$RoutesTableReferences
                              ._routeLinesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$RoutesTableReferences(
                                db,
                                table,
                                p0,
                              ).routeLinesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.routeId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (ascentsRefs)
                        await $_getPrefetchedData<Route, $RoutesTable, Ascent>(
                          currentTable: table,
                          referencedTable: $$RoutesTableReferences
                              ._ascentsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$RoutesTableReferences(
                                db,
                                table,
                                p0,
                              ).ascentsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.routeId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$RoutesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RoutesTable,
      Route,
      $$RoutesTableFilterComposer,
      $$RoutesTableOrderingComposer,
      $$RoutesTableAnnotationComposer,
      $$RoutesTableCreateCompanionBuilder,
      $$RoutesTableUpdateCompanionBuilder,
      (Route, $$RoutesTableReferences),
      Route,
      PrefetchHooks Function({
        bool wallId,
        bool photoId,
        bool routeLinesRefs,
        bool ascentsRefs,
      })
    >;
typedef $$RouteLinesTableCreateCompanionBuilder =
    RouteLinesCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      required String routeId,
      required String photoId,
      required String pointsJson,
      required String symbolsJson,
      Value<int> rowid,
    });
typedef $$RouteLinesTableUpdateCompanionBuilder =
    RouteLinesCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String> routeId,
      Value<String> photoId,
      Value<String> pointsJson,
      Value<String> symbolsJson,
      Value<int> rowid,
    });

final class $$RouteLinesTableReferences
    extends BaseReferences<_$AppDatabase, $RouteLinesTable, RouteLine> {
  $$RouteLinesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $RoutesTable _routeIdTable(_$AppDatabase db) =>
      db.routes.createAlias('route_lines__route_id__routes__id');

  $$RoutesTableProcessedTableManager get routeId {
    final $_column = $_itemColumn<String>('route_id')!;

    final manager = $$RoutesTableTableManager(
      $_db,
      $_db.routes,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_routeIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PhotosTable _photoIdTable(_$AppDatabase db) =>
      db.photos.createAlias('route_lines__photo_id__photos__id');

  $$PhotosTableProcessedTableManager get photoId {
    final $_column = $_itemColumn<String>('photo_id')!;

    final manager = $$PhotosTableTableManager(
      $_db,
      $_db.photos,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_photoIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$RouteLinesTableFilterComposer
    extends Composer<_$AppDatabase, $RouteLinesTable> {
  $$RouteLinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get symbolsJson => $composableBuilder(
    column: $table.symbolsJson,
    builder: (column) => ColumnFilters(column),
  );

  $$RoutesTableFilterComposer get routeId {
    final $$RoutesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.routeId,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableFilterComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableFilterComposer get photoId {
    final $$PhotosTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.photoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableFilterComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RouteLinesTableOrderingComposer
    extends Composer<_$AppDatabase, $RouteLinesTable> {
  $$RouteLinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get symbolsJson => $composableBuilder(
    column: $table.symbolsJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$RoutesTableOrderingComposer get routeId {
    final $$RoutesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.routeId,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableOrderingComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableOrderingComposer get photoId {
    final $$PhotosTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.photoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableOrderingComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RouteLinesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RouteLinesTable> {
  $$RouteLinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get symbolsJson => $composableBuilder(
    column: $table.symbolsJson,
    builder: (column) => column,
  );

  $$RoutesTableAnnotationComposer get routeId {
    final $$RoutesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.routeId,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableAnnotationComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PhotosTableAnnotationComposer get photoId {
    final $$PhotosTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.photoId,
      referencedTable: $db.photos,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PhotosTableAnnotationComposer(
            $db: $db,
            $table: $db.photos,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RouteLinesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RouteLinesTable,
          RouteLine,
          $$RouteLinesTableFilterComposer,
          $$RouteLinesTableOrderingComposer,
          $$RouteLinesTableAnnotationComposer,
          $$RouteLinesTableCreateCompanionBuilder,
          $$RouteLinesTableUpdateCompanionBuilder,
          (RouteLine, $$RouteLinesTableReferences),
          RouteLine,
          PrefetchHooks Function({bool routeId, bool photoId})
        > {
  $$RouteLinesTableTableManager(_$AppDatabase db, $RouteLinesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RouteLinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RouteLinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RouteLinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String> routeId = const Value.absent(),
                Value<String> photoId = const Value.absent(),
                Value<String> pointsJson = const Value.absent(),
                Value<String> symbolsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RouteLinesCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                routeId: routeId,
                photoId: photoId,
                pointsJson: pointsJson,
                symbolsJson: symbolsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                required String routeId,
                required String photoId,
                required String pointsJson,
                required String symbolsJson,
                Value<int> rowid = const Value.absent(),
              }) => RouteLinesCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                routeId: routeId,
                photoId: photoId,
                pointsJson: pointsJson,
                symbolsJson: symbolsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RouteLinesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({routeId = false, photoId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (routeId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.routeId,
                                referencedTable: $$RouteLinesTableReferences
                                    ._routeIdTable(db),
                                referencedColumn: $$RouteLinesTableReferences
                                    ._routeIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (photoId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.photoId,
                                referencedTable: $$RouteLinesTableReferences
                                    ._photoIdTable(db),
                                referencedColumn: $$RouteLinesTableReferences
                                    ._photoIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$RouteLinesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RouteLinesTable,
      RouteLine,
      $$RouteLinesTableFilterComposer,
      $$RouteLinesTableOrderingComposer,
      $$RouteLinesTableAnnotationComposer,
      $$RouteLinesTableCreateCompanionBuilder,
      $$RouteLinesTableUpdateCompanionBuilder,
      (RouteLine, $$RouteLinesTableReferences),
      RouteLine,
      PrefetchHooks Function({bool routeId, bool photoId})
    >;
typedef $$AscentsTableCreateCompanionBuilder =
    AscentsCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      required String routeId,
      required String wallId,
      required int climbedAt,
      required String style,
      Value<String?> notes,
      Value<String?> gradeOpinion,
      Value<String> visibility,
      Value<String?> authorName,
      Value<int> rowid,
    });
typedef $$AscentsTableUpdateCompanionBuilder =
    AscentsCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String> routeId,
      Value<String> wallId,
      Value<int> climbedAt,
      Value<String> style,
      Value<String?> notes,
      Value<String?> gradeOpinion,
      Value<String> visibility,
      Value<String?> authorName,
      Value<int> rowid,
    });

final class $$AscentsTableReferences
    extends BaseReferences<_$AppDatabase, $AscentsTable, Ascent> {
  $$AscentsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $RoutesTable _routeIdTable(_$AppDatabase db) =>
      db.routes.createAlias('ascents__route_id__routes__id');

  $$RoutesTableProcessedTableManager get routeId {
    final $_column = $_itemColumn<String>('route_id')!;

    final manager = $$RoutesTableTableManager(
      $_db,
      $_db.routes,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_routeIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $WallsTable _wallIdTable(_$AppDatabase db) =>
      db.walls.createAlias('ascents__wall_id__walls__id');

  $$WallsTableProcessedTableManager get wallId {
    final $_column = $_itemColumn<String>('wall_id')!;

    final manager = $$WallsTableTableManager(
      $_db,
      $_db.walls,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_wallIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$CommentsTable, List<Comment>> _commentsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.comments,
    aliasName: 'ascents__id__comments__ascent_id',
  );

  $$CommentsTableProcessedTableManager get commentsRefs {
    final manager = $$CommentsTableTableManager(
      $_db,
      $_db.comments,
    ).filter((f) => f.ascentId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_commentsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LikesTable, List<Like>> _likesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.likes,
    aliasName: 'ascents__id__likes__ascent_id',
  );

  $$LikesTableProcessedTableManager get likesRefs {
    final manager = $$LikesTableTableManager(
      $_db,
      $_db.likes,
    ).filter((f) => f.ascentId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_likesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AscentsTableFilterComposer
    extends Composer<_$AppDatabase, $AscentsTable> {
  $$AscentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get climbedAt => $composableBuilder(
    column: $table.climbedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get style => $composableBuilder(
    column: $table.style,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gradeOpinion => $composableBuilder(
    column: $table.gradeOpinion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorName => $composableBuilder(
    column: $table.authorName,
    builder: (column) => ColumnFilters(column),
  );

  $$RoutesTableFilterComposer get routeId {
    final $$RoutesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.routeId,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableFilterComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$WallsTableFilterComposer get wallId {
    final $$WallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableFilterComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> commentsRefs(
    Expression<bool> Function($$CommentsTableFilterComposer f) f,
  ) {
    final $$CommentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.comments,
      getReferencedColumn: (t) => t.ascentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CommentsTableFilterComposer(
            $db: $db,
            $table: $db.comments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> likesRefs(
    Expression<bool> Function($$LikesTableFilterComposer f) f,
  ) {
    final $$LikesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.likes,
      getReferencedColumn: (t) => t.ascentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LikesTableFilterComposer(
            $db: $db,
            $table: $db.likes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AscentsTableOrderingComposer
    extends Composer<_$AppDatabase, $AscentsTable> {
  $$AscentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get climbedAt => $composableBuilder(
    column: $table.climbedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get style => $composableBuilder(
    column: $table.style,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gradeOpinion => $composableBuilder(
    column: $table.gradeOpinion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorName => $composableBuilder(
    column: $table.authorName,
    builder: (column) => ColumnOrderings(column),
  );

  $$RoutesTableOrderingComposer get routeId {
    final $$RoutesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.routeId,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableOrderingComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$WallsTableOrderingComposer get wallId {
    final $$WallsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableOrderingComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AscentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AscentsTable> {
  $$AscentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<int> get climbedAt =>
      $composableBuilder(column: $table.climbedAt, builder: (column) => column);

  GeneratedColumn<String> get style =>
      $composableBuilder(column: $table.style, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get gradeOpinion => $composableBuilder(
    column: $table.gradeOpinion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get visibility => $composableBuilder(
    column: $table.visibility,
    builder: (column) => column,
  );

  GeneratedColumn<String> get authorName => $composableBuilder(
    column: $table.authorName,
    builder: (column) => column,
  );

  $$RoutesTableAnnotationComposer get routeId {
    final $$RoutesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.routeId,
      referencedTable: $db.routes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoutesTableAnnotationComposer(
            $db: $db,
            $table: $db.routes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$WallsTableAnnotationComposer get wallId {
    final $$WallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableAnnotationComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> commentsRefs<T extends Object>(
    Expression<T> Function($$CommentsTableAnnotationComposer a) f,
  ) {
    final $$CommentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.comments,
      getReferencedColumn: (t) => t.ascentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CommentsTableAnnotationComposer(
            $db: $db,
            $table: $db.comments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> likesRefs<T extends Object>(
    Expression<T> Function($$LikesTableAnnotationComposer a) f,
  ) {
    final $$LikesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.likes,
      getReferencedColumn: (t) => t.ascentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LikesTableAnnotationComposer(
            $db: $db,
            $table: $db.likes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AscentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AscentsTable,
          Ascent,
          $$AscentsTableFilterComposer,
          $$AscentsTableOrderingComposer,
          $$AscentsTableAnnotationComposer,
          $$AscentsTableCreateCompanionBuilder,
          $$AscentsTableUpdateCompanionBuilder,
          (Ascent, $$AscentsTableReferences),
          Ascent,
          PrefetchHooks Function({
            bool routeId,
            bool wallId,
            bool commentsRefs,
            bool likesRefs,
          })
        > {
  $$AscentsTableTableManager(_$AppDatabase db, $AscentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AscentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AscentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AscentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String> routeId = const Value.absent(),
                Value<String> wallId = const Value.absent(),
                Value<int> climbedAt = const Value.absent(),
                Value<String> style = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> gradeOpinion = const Value.absent(),
                Value<String> visibility = const Value.absent(),
                Value<String?> authorName = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AscentsCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                routeId: routeId,
                wallId: wallId,
                climbedAt: climbedAt,
                style: style,
                notes: notes,
                gradeOpinion: gradeOpinion,
                visibility: visibility,
                authorName: authorName,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                required String routeId,
                required String wallId,
                required int climbedAt,
                required String style,
                Value<String?> notes = const Value.absent(),
                Value<String?> gradeOpinion = const Value.absent(),
                Value<String> visibility = const Value.absent(),
                Value<String?> authorName = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AscentsCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                routeId: routeId,
                wallId: wallId,
                climbedAt: climbedAt,
                style: style,
                notes: notes,
                gradeOpinion: gradeOpinion,
                visibility: visibility,
                authorName: authorName,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$AscentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                routeId = false,
                wallId = false,
                commentsRefs = false,
                likesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (commentsRefs) db.comments,
                    if (likesRefs) db.likes,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (routeId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.routeId,
                                    referencedTable: $$AscentsTableReferences
                                        ._routeIdTable(db),
                                    referencedColumn: $$AscentsTableReferences
                                        ._routeIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (wallId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.wallId,
                                    referencedTable: $$AscentsTableReferences
                                        ._wallIdTable(db),
                                    referencedColumn: $$AscentsTableReferences
                                        ._wallIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (commentsRefs)
                        await $_getPrefetchedData<
                          Ascent,
                          $AscentsTable,
                          Comment
                        >(
                          currentTable: table,
                          referencedTable: $$AscentsTableReferences
                              ._commentsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AscentsTableReferences(
                                db,
                                table,
                                p0,
                              ).commentsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.ascentId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (likesRefs)
                        await $_getPrefetchedData<Ascent, $AscentsTable, Like>(
                          currentTable: table,
                          referencedTable: $$AscentsTableReferences
                              ._likesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AscentsTableReferences(db, table, p0).likesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.ascentId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$AscentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AscentsTable,
      Ascent,
      $$AscentsTableFilterComposer,
      $$AscentsTableOrderingComposer,
      $$AscentsTableAnnotationComposer,
      $$AscentsTableCreateCompanionBuilder,
      $$AscentsTableUpdateCompanionBuilder,
      (Ascent, $$AscentsTableReferences),
      Ascent,
      PrefetchHooks Function({
        bool routeId,
        bool wallId,
        bool commentsRefs,
        bool likesRefs,
      })
    >;
typedef $$CommentsTableCreateCompanionBuilder =
    CommentsCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> wallId,
      required String body,
      Value<String?> authorName,
      Value<String?> ascentId,
      Value<String?> mentionedUids,
      Value<int> rowid,
    });
typedef $$CommentsTableUpdateCompanionBuilder =
    CommentsCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> wallId,
      Value<String> body,
      Value<String?> authorName,
      Value<String?> ascentId,
      Value<String?> mentionedUids,
      Value<int> rowid,
    });

final class $$CommentsTableReferences
    extends BaseReferences<_$AppDatabase, $CommentsTable, Comment> {
  $$CommentsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $WallsTable _wallIdTable(_$AppDatabase db) =>
      db.walls.createAlias('comments__wall_id__walls__id');

  $$WallsTableProcessedTableManager? get wallId {
    final $_column = $_itemColumn<String>('wall_id');
    if ($_column == null) return null;
    final manager = $$WallsTableTableManager(
      $_db,
      $_db.walls,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_wallIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $AscentsTable _ascentIdTable(_$AppDatabase db) =>
      db.ascents.createAlias('comments__ascent_id__ascents__id');

  $$AscentsTableProcessedTableManager? get ascentId {
    final $_column = $_itemColumn<String>('ascent_id');
    if ($_column == null) return null;
    final manager = $$AscentsTableTableManager(
      $_db,
      $_db.ascents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_ascentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CommentsTableFilterComposer
    extends Composer<_$AppDatabase, $CommentsTable> {
  $$CommentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorName => $composableBuilder(
    column: $table.authorName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mentionedUids => $composableBuilder(
    column: $table.mentionedUids,
    builder: (column) => ColumnFilters(column),
  );

  $$WallsTableFilterComposer get wallId {
    final $$WallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableFilterComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AscentsTableFilterComposer get ascentId {
    final $$AscentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ascentId,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableFilterComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CommentsTableOrderingComposer
    extends Composer<_$AppDatabase, $CommentsTable> {
  $$CommentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorName => $composableBuilder(
    column: $table.authorName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mentionedUids => $composableBuilder(
    column: $table.mentionedUids,
    builder: (column) => ColumnOrderings(column),
  );

  $$WallsTableOrderingComposer get wallId {
    final $$WallsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableOrderingComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AscentsTableOrderingComposer get ascentId {
    final $$AscentsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ascentId,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableOrderingComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CommentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CommentsTable> {
  $$CommentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get authorName => $composableBuilder(
    column: $table.authorName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mentionedUids => $composableBuilder(
    column: $table.mentionedUids,
    builder: (column) => column,
  );

  $$WallsTableAnnotationComposer get wallId {
    final $$WallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableAnnotationComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AscentsTableAnnotationComposer get ascentId {
    final $$AscentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ascentId,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableAnnotationComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CommentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CommentsTable,
          Comment,
          $$CommentsTableFilterComposer,
          $$CommentsTableOrderingComposer,
          $$CommentsTableAnnotationComposer,
          $$CommentsTableCreateCompanionBuilder,
          $$CommentsTableUpdateCompanionBuilder,
          (Comment, $$CommentsTableReferences),
          Comment,
          PrefetchHooks Function({bool wallId, bool ascentId})
        > {
  $$CommentsTableTableManager(_$AppDatabase db, $CommentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CommentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CommentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CommentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> wallId = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String?> authorName = const Value.absent(),
                Value<String?> ascentId = const Value.absent(),
                Value<String?> mentionedUids = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CommentsCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                body: body,
                authorName: authorName,
                ascentId: ascentId,
                mentionedUids: mentionedUids,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> wallId = const Value.absent(),
                required String body,
                Value<String?> authorName = const Value.absent(),
                Value<String?> ascentId = const Value.absent(),
                Value<String?> mentionedUids = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CommentsCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                body: body,
                authorName: authorName,
                ascentId: ascentId,
                mentionedUids: mentionedUids,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CommentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({wallId = false, ascentId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (wallId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.wallId,
                                referencedTable: $$CommentsTableReferences
                                    ._wallIdTable(db),
                                referencedColumn: $$CommentsTableReferences
                                    ._wallIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (ascentId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.ascentId,
                                referencedTable: $$CommentsTableReferences
                                    ._ascentIdTable(db),
                                referencedColumn: $$CommentsTableReferences
                                    ._ascentIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CommentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CommentsTable,
      Comment,
      $$CommentsTableFilterComposer,
      $$CommentsTableOrderingComposer,
      $$CommentsTableAnnotationComposer,
      $$CommentsTableCreateCompanionBuilder,
      $$CommentsTableUpdateCompanionBuilder,
      (Comment, $$CommentsTableReferences),
      Comment,
      PrefetchHooks Function({bool wallId, bool ascentId})
    >;
typedef $$LikesTableCreateCompanionBuilder =
    LikesCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> wallId,
      Value<String?> ascentId,
      Value<int> rowid,
    });
typedef $$LikesTableUpdateCompanionBuilder =
    LikesCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> wallId,
      Value<String?> ascentId,
      Value<int> rowid,
    });

final class $$LikesTableReferences
    extends BaseReferences<_$AppDatabase, $LikesTable, Like> {
  $$LikesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $WallsTable _wallIdTable(_$AppDatabase db) =>
      db.walls.createAlias('likes__wall_id__walls__id');

  $$WallsTableProcessedTableManager? get wallId {
    final $_column = $_itemColumn<String>('wall_id');
    if ($_column == null) return null;
    final manager = $$WallsTableTableManager(
      $_db,
      $_db.walls,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_wallIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $AscentsTable _ascentIdTable(_$AppDatabase db) =>
      db.ascents.createAlias('likes__ascent_id__ascents__id');

  $$AscentsTableProcessedTableManager? get ascentId {
    final $_column = $_itemColumn<String>('ascent_id');
    if ($_column == null) return null;
    final manager = $$AscentsTableTableManager(
      $_db,
      $_db.ascents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_ascentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LikesTableFilterComposer extends Composer<_$AppDatabase, $LikesTable> {
  $$LikesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  $$WallsTableFilterComposer get wallId {
    final $$WallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableFilterComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AscentsTableFilterComposer get ascentId {
    final $$AscentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ascentId,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableFilterComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LikesTableOrderingComposer
    extends Composer<_$AppDatabase, $LikesTable> {
  $$LikesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  $$WallsTableOrderingComposer get wallId {
    final $$WallsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableOrderingComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AscentsTableOrderingComposer get ascentId {
    final $$AscentsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ascentId,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableOrderingComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LikesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LikesTable> {
  $$LikesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  $$WallsTableAnnotationComposer get wallId {
    final $$WallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.wallId,
      referencedTable: $db.walls,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WallsTableAnnotationComposer(
            $db: $db,
            $table: $db.walls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AscentsTableAnnotationComposer get ascentId {
    final $$AscentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ascentId,
      referencedTable: $db.ascents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AscentsTableAnnotationComposer(
            $db: $db,
            $table: $db.ascents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LikesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LikesTable,
          Like,
          $$LikesTableFilterComposer,
          $$LikesTableOrderingComposer,
          $$LikesTableAnnotationComposer,
          $$LikesTableCreateCompanionBuilder,
          $$LikesTableUpdateCompanionBuilder,
          (Like, $$LikesTableReferences),
          Like,
          PrefetchHooks Function({bool wallId, bool ascentId})
        > {
  $$LikesTableTableManager(_$AppDatabase db, $LikesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LikesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LikesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LikesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> wallId = const Value.absent(),
                Value<String?> ascentId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LikesCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                ascentId: ascentId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> wallId = const Value.absent(),
                Value<String?> ascentId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LikesCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                wallId: wallId,
                ascentId: ascentId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$LikesTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({wallId = false, ascentId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (wallId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.wallId,
                                referencedTable: $$LikesTableReferences
                                    ._wallIdTable(db),
                                referencedColumn: $$LikesTableReferences
                                    ._wallIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (ascentId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.ascentId,
                                referencedTable: $$LikesTableReferences
                                    ._ascentIdTable(db),
                                referencedColumn: $$LikesTableReferences
                                    ._ascentIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LikesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LikesTable,
      Like,
      $$LikesTableFilterComposer,
      $$LikesTableOrderingComposer,
      $$LikesTableAnnotationComposer,
      $$LikesTableCreateCompanionBuilder,
      $$LikesTableUpdateCompanionBuilder,
      (Like, $$LikesTableReferences),
      Like,
      PrefetchHooks Function({bool wallId, bool ascentId})
    >;
typedef $$ProfilesTableCreateCompanionBuilder =
    ProfilesCompanion Function({
      required String id,
      required int createdAt,
      required int updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> displayName,
      Value<String?> avatarUrl,
      Value<int> rowid,
    });
typedef $$ProfilesTableUpdateCompanionBuilder =
    ProfilesCompanion Function({
      Value<String> id,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> deletedAt,
      Value<String?> remoteId,
      Value<bool> dirty,
      Value<String?> ownerId,
      Value<String?> displayName,
      Value<String?> avatarUrl,
      Value<int> rowid,
    });

class $$ProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarUrl => $composableBuilder(
    column: $table.avatarUrl,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarUrl => $composableBuilder(
    column: $table.avatarUrl,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatarUrl =>
      $composableBuilder(column: $table.avatarUrl, builder: (column) => column);
}

class $$ProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfilesTable,
          Profile,
          $$ProfilesTableFilterComposer,
          $$ProfilesTableOrderingComposer,
          $$ProfilesTableAnnotationComposer,
          $$ProfilesTableCreateCompanionBuilder,
          $$ProfilesTableUpdateCompanionBuilder,
          (Profile, BaseReferences<_$AppDatabase, $ProfilesTable, Profile>),
          Profile,
          PrefetchHooks Function()
        > {
  $$ProfilesTableTableManager(_$AppDatabase db, $ProfilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> displayName = const Value.absent(),
                Value<String?> avatarUrl = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                displayName: displayName,
                avatarUrl: avatarUrl,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAt,
                required int updatedAt,
                Value<int?> deletedAt = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String?> ownerId = const Value.absent(),
                Value<String?> displayName = const Value.absent(),
                Value<String?> avatarUrl = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion.insert(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                remoteId: remoteId,
                dirty: dirty,
                ownerId: ownerId,
                displayName: displayName,
                avatarUrl: avatarUrl,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfilesTable,
      Profile,
      $$ProfilesTableFilterComposer,
      $$ProfilesTableOrderingComposer,
      $$ProfilesTableAnnotationComposer,
      $$ProfilesTableCreateCompanionBuilder,
      $$ProfilesTableUpdateCompanionBuilder,
      (Profile, BaseReferences<_$AppDatabase, $ProfilesTable, Profile>),
      Profile,
      PrefetchHooks Function()
    >;
typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String settingKey,
      Value<String?> settingValue,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> settingKey,
      Value<String?> settingValue,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get settingValue => $composableBuilder(
    column: $table.settingValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get settingValue => $composableBuilder(
    column: $table.settingValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get settingValue => $composableBuilder(
    column: $table.settingValue,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSettingsTable,
          AppSettingRow,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSettingRow,
            BaseReferences<_$AppDatabase, $AppSettingsTable, AppSettingRow>,
          ),
          AppSettingRow,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(_$AppDatabase db, $AppSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> settingKey = const Value.absent(),
                Value<String?> settingValue = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion(
                settingKey: settingKey,
                settingValue: settingValue,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String settingKey,
                Value<String?> settingValue = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                settingKey: settingKey,
                settingValue: settingValue,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSettingsTable,
      AppSettingRow,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSettingRow,
        BaseReferences<_$AppDatabase, $AppSettingsTable, AppSettingRow>,
      ),
      AppSettingRow,
      PrefetchHooks Function()
    >;
typedef $$WallModerationRowsTableCreateCompanionBuilder =
    WallModerationRowsCompanion Function({
      required String wallId,
      required String state,
      Value<int?> submittedAt,
      Value<int?> reviewedAt,
      Value<String?> reviewerId,
      Value<String?> rejectionReason,
      Value<int?> withdrawRequestedAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$WallModerationRowsTableUpdateCompanionBuilder =
    WallModerationRowsCompanion Function({
      Value<String> wallId,
      Value<String> state,
      Value<int?> submittedAt,
      Value<int?> reviewedAt,
      Value<String?> reviewerId,
      Value<String?> rejectionReason,
      Value<int?> withdrawRequestedAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$WallModerationRowsTableFilterComposer
    extends Composer<_$AppDatabase, $WallModerationRowsTable> {
  $$WallModerationRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get submittedAt => $composableBuilder(
    column: $table.submittedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reviewerId => $composableBuilder(
    column: $table.reviewerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rejectionReason => $composableBuilder(
    column: $table.rejectionReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get withdrawRequestedAt => $composableBuilder(
    column: $table.withdrawRequestedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WallModerationRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $WallModerationRowsTable> {
  $$WallModerationRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get submittedAt => $composableBuilder(
    column: $table.submittedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reviewerId => $composableBuilder(
    column: $table.reviewerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rejectionReason => $composableBuilder(
    column: $table.rejectionReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get withdrawRequestedAt => $composableBuilder(
    column: $table.withdrawRequestedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WallModerationRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $WallModerationRowsTable> {
  $$WallModerationRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get wallId =>
      $composableBuilder(column: $table.wallId, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get submittedAt => $composableBuilder(
    column: $table.submittedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reviewerId => $composableBuilder(
    column: $table.reviewerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rejectionReason => $composableBuilder(
    column: $table.rejectionReason,
    builder: (column) => column,
  );

  GeneratedColumn<int> get withdrawRequestedAt => $composableBuilder(
    column: $table.withdrawRequestedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$WallModerationRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WallModerationRowsTable,
          WallModerationRow,
          $$WallModerationRowsTableFilterComposer,
          $$WallModerationRowsTableOrderingComposer,
          $$WallModerationRowsTableAnnotationComposer,
          $$WallModerationRowsTableCreateCompanionBuilder,
          $$WallModerationRowsTableUpdateCompanionBuilder,
          (
            WallModerationRow,
            BaseReferences<
              _$AppDatabase,
              $WallModerationRowsTable,
              WallModerationRow
            >,
          ),
          WallModerationRow,
          PrefetchHooks Function()
        > {
  $$WallModerationRowsTableTableManager(
    _$AppDatabase db,
    $WallModerationRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WallModerationRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WallModerationRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WallModerationRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> wallId = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int?> submittedAt = const Value.absent(),
                Value<int?> reviewedAt = const Value.absent(),
                Value<String?> reviewerId = const Value.absent(),
                Value<String?> rejectionReason = const Value.absent(),
                Value<int?> withdrawRequestedAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WallModerationRowsCompanion(
                wallId: wallId,
                state: state,
                submittedAt: submittedAt,
                reviewedAt: reviewedAt,
                reviewerId: reviewerId,
                rejectionReason: rejectionReason,
                withdrawRequestedAt: withdrawRequestedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String wallId,
                required String state,
                Value<int?> submittedAt = const Value.absent(),
                Value<int?> reviewedAt = const Value.absent(),
                Value<String?> reviewerId = const Value.absent(),
                Value<String?> rejectionReason = const Value.absent(),
                Value<int?> withdrawRequestedAt = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => WallModerationRowsCompanion.insert(
                wallId: wallId,
                state: state,
                submittedAt: submittedAt,
                reviewedAt: reviewedAt,
                reviewerId: reviewerId,
                rejectionReason: rejectionReason,
                withdrawRequestedAt: withdrawRequestedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WallModerationRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WallModerationRowsTable,
      WallModerationRow,
      $$WallModerationRowsTableFilterComposer,
      $$WallModerationRowsTableOrderingComposer,
      $$WallModerationRowsTableAnnotationComposer,
      $$WallModerationRowsTableCreateCompanionBuilder,
      $$WallModerationRowsTableUpdateCompanionBuilder,
      (
        WallModerationRow,
        BaseReferences<
          _$AppDatabase,
          $WallModerationRowsTable,
          WallModerationRow
        >,
      ),
      WallModerationRow,
      PrefetchHooks Function()
    >;
typedef $$GradeOpinionRowsTableCreateCompanionBuilder =
    GradeOpinionRowsCompanion Function({
      required String id,
      required String routeId,
      required String authorId,
      required String gradeSystem,
      required String gradeRaw,
      Value<double?> gradeSortKey,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$GradeOpinionRowsTableUpdateCompanionBuilder =
    GradeOpinionRowsCompanion Function({
      Value<String> id,
      Value<String> routeId,
      Value<String> authorId,
      Value<String> gradeSystem,
      Value<String> gradeRaw,
      Value<double?> gradeSortKey,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$GradeOpinionRowsTableFilterComposer
    extends Composer<_$AppDatabase, $GradeOpinionRowsTable> {
  $$GradeOpinionRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get routeId => $composableBuilder(
    column: $table.routeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorId => $composableBuilder(
    column: $table.authorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gradeSystem => $composableBuilder(
    column: $table.gradeSystem,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gradeRaw => $composableBuilder(
    column: $table.gradeRaw,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get gradeSortKey => $composableBuilder(
    column: $table.gradeSortKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GradeOpinionRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $GradeOpinionRowsTable> {
  $$GradeOpinionRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get routeId => $composableBuilder(
    column: $table.routeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorId => $composableBuilder(
    column: $table.authorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gradeSystem => $composableBuilder(
    column: $table.gradeSystem,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gradeRaw => $composableBuilder(
    column: $table.gradeRaw,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get gradeSortKey => $composableBuilder(
    column: $table.gradeSortKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GradeOpinionRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $GradeOpinionRowsTable> {
  $$GradeOpinionRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get routeId =>
      $composableBuilder(column: $table.routeId, builder: (column) => column);

  GeneratedColumn<String> get authorId =>
      $composableBuilder(column: $table.authorId, builder: (column) => column);

  GeneratedColumn<String> get gradeSystem => $composableBuilder(
    column: $table.gradeSystem,
    builder: (column) => column,
  );

  GeneratedColumn<String> get gradeRaw =>
      $composableBuilder(column: $table.gradeRaw, builder: (column) => column);

  GeneratedColumn<double> get gradeSortKey => $composableBuilder(
    column: $table.gradeSortKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$GradeOpinionRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GradeOpinionRowsTable,
          GradeOpinionRow,
          $$GradeOpinionRowsTableFilterComposer,
          $$GradeOpinionRowsTableOrderingComposer,
          $$GradeOpinionRowsTableAnnotationComposer,
          $$GradeOpinionRowsTableCreateCompanionBuilder,
          $$GradeOpinionRowsTableUpdateCompanionBuilder,
          (
            GradeOpinionRow,
            BaseReferences<
              _$AppDatabase,
              $GradeOpinionRowsTable,
              GradeOpinionRow
            >,
          ),
          GradeOpinionRow,
          PrefetchHooks Function()
        > {
  $$GradeOpinionRowsTableTableManager(
    _$AppDatabase db,
    $GradeOpinionRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GradeOpinionRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GradeOpinionRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GradeOpinionRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> routeId = const Value.absent(),
                Value<String> authorId = const Value.absent(),
                Value<String> gradeSystem = const Value.absent(),
                Value<String> gradeRaw = const Value.absent(),
                Value<double?> gradeSortKey = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GradeOpinionRowsCompanion(
                id: id,
                routeId: routeId,
                authorId: authorId,
                gradeSystem: gradeSystem,
                gradeRaw: gradeRaw,
                gradeSortKey: gradeSortKey,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String routeId,
                required String authorId,
                required String gradeSystem,
                required String gradeRaw,
                Value<double?> gradeSortKey = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => GradeOpinionRowsCompanion.insert(
                id: id,
                routeId: routeId,
                authorId: authorId,
                gradeSystem: gradeSystem,
                gradeRaw: gradeRaw,
                gradeSortKey: gradeSortKey,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GradeOpinionRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GradeOpinionRowsTable,
      GradeOpinionRow,
      $$GradeOpinionRowsTableFilterComposer,
      $$GradeOpinionRowsTableOrderingComposer,
      $$GradeOpinionRowsTableAnnotationComposer,
      $$GradeOpinionRowsTableCreateCompanionBuilder,
      $$GradeOpinionRowsTableUpdateCompanionBuilder,
      (
        GradeOpinionRow,
        BaseReferences<_$AppDatabase, $GradeOpinionRowsTable, GradeOpinionRow>,
      ),
      GradeOpinionRow,
      PrefetchHooks Function()
    >;
typedef $$TopoVerificationRowsTableCreateCompanionBuilder =
    TopoVerificationRowsCompanion Function({
      required String id,
      required String wallId,
      required String authorId,
      required bool accurate,
      Value<String?> note,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$TopoVerificationRowsTableUpdateCompanionBuilder =
    TopoVerificationRowsCompanion Function({
      Value<String> id,
      Value<String> wallId,
      Value<String> authorId,
      Value<bool> accurate,
      Value<String?> note,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$TopoVerificationRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TopoVerificationRowsTable> {
  $$TopoVerificationRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorId => $composableBuilder(
    column: $table.authorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get accurate => $composableBuilder(
    column: $table.accurate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TopoVerificationRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TopoVerificationRowsTable> {
  $$TopoVerificationRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorId => $composableBuilder(
    column: $table.authorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get accurate => $composableBuilder(
    column: $table.accurate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TopoVerificationRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TopoVerificationRowsTable> {
  $$TopoVerificationRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get wallId =>
      $composableBuilder(column: $table.wallId, builder: (column) => column);

  GeneratedColumn<String> get authorId =>
      $composableBuilder(column: $table.authorId, builder: (column) => column);

  GeneratedColumn<bool> get accurate =>
      $composableBuilder(column: $table.accurate, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$TopoVerificationRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TopoVerificationRowsTable,
          TopoVerificationRow,
          $$TopoVerificationRowsTableFilterComposer,
          $$TopoVerificationRowsTableOrderingComposer,
          $$TopoVerificationRowsTableAnnotationComposer,
          $$TopoVerificationRowsTableCreateCompanionBuilder,
          $$TopoVerificationRowsTableUpdateCompanionBuilder,
          (
            TopoVerificationRow,
            BaseReferences<
              _$AppDatabase,
              $TopoVerificationRowsTable,
              TopoVerificationRow
            >,
          ),
          TopoVerificationRow,
          PrefetchHooks Function()
        > {
  $$TopoVerificationRowsTableTableManager(
    _$AppDatabase db,
    $TopoVerificationRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TopoVerificationRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TopoVerificationRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TopoVerificationRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> wallId = const Value.absent(),
                Value<String> authorId = const Value.absent(),
                Value<bool> accurate = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TopoVerificationRowsCompanion(
                id: id,
                wallId: wallId,
                authorId: authorId,
                accurate: accurate,
                note: note,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String wallId,
                required String authorId,
                required bool accurate,
                Value<String?> note = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => TopoVerificationRowsCompanion.insert(
                id: id,
                wallId: wallId,
                authorId: authorId,
                accurate: accurate,
                note: note,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TopoVerificationRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TopoVerificationRowsTable,
      TopoVerificationRow,
      $$TopoVerificationRowsTableFilterComposer,
      $$TopoVerificationRowsTableOrderingComposer,
      $$TopoVerificationRowsTableAnnotationComposer,
      $$TopoVerificationRowsTableCreateCompanionBuilder,
      $$TopoVerificationRowsTableUpdateCompanionBuilder,
      (
        TopoVerificationRow,
        BaseReferences<
          _$AppDatabase,
          $TopoVerificationRowsTable,
          TopoVerificationRow
        >,
      ),
      TopoVerificationRow,
      PrefetchHooks Function()
    >;
typedef $$TopoHazardRowsTableCreateCompanionBuilder =
    TopoHazardRowsCompanion Function({
      required String id,
      required String wallId,
      Value<String?> routeId,
      required String authorId,
      required String severity,
      required String body,
      Value<int?> resolvedAt,
      Value<String?> resolvedBy,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$TopoHazardRowsTableUpdateCompanionBuilder =
    TopoHazardRowsCompanion Function({
      Value<String> id,
      Value<String> wallId,
      Value<String?> routeId,
      Value<String> authorId,
      Value<String> severity,
      Value<String> body,
      Value<int?> resolvedAt,
      Value<String?> resolvedBy,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$TopoHazardRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TopoHazardRowsTable> {
  $$TopoHazardRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get routeId => $composableBuilder(
    column: $table.routeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorId => $composableBuilder(
    column: $table.authorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get resolvedAt => $composableBuilder(
    column: $table.resolvedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resolvedBy => $composableBuilder(
    column: $table.resolvedBy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TopoHazardRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TopoHazardRowsTable> {
  $$TopoHazardRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get routeId => $composableBuilder(
    column: $table.routeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorId => $composableBuilder(
    column: $table.authorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get resolvedAt => $composableBuilder(
    column: $table.resolvedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resolvedBy => $composableBuilder(
    column: $table.resolvedBy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TopoHazardRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TopoHazardRowsTable> {
  $$TopoHazardRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get wallId =>
      $composableBuilder(column: $table.wallId, builder: (column) => column);

  GeneratedColumn<String> get routeId =>
      $composableBuilder(column: $table.routeId, builder: (column) => column);

  GeneratedColumn<String> get authorId =>
      $composableBuilder(column: $table.authorId, builder: (column) => column);

  GeneratedColumn<String> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<int> get resolvedAt => $composableBuilder(
    column: $table.resolvedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resolvedBy => $composableBuilder(
    column: $table.resolvedBy,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$TopoHazardRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TopoHazardRowsTable,
          TopoHazardRow,
          $$TopoHazardRowsTableFilterComposer,
          $$TopoHazardRowsTableOrderingComposer,
          $$TopoHazardRowsTableAnnotationComposer,
          $$TopoHazardRowsTableCreateCompanionBuilder,
          $$TopoHazardRowsTableUpdateCompanionBuilder,
          (
            TopoHazardRow,
            BaseReferences<_$AppDatabase, $TopoHazardRowsTable, TopoHazardRow>,
          ),
          TopoHazardRow,
          PrefetchHooks Function()
        > {
  $$TopoHazardRowsTableTableManager(
    _$AppDatabase db,
    $TopoHazardRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TopoHazardRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TopoHazardRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TopoHazardRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> wallId = const Value.absent(),
                Value<String?> routeId = const Value.absent(),
                Value<String> authorId = const Value.absent(),
                Value<String> severity = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<int?> resolvedAt = const Value.absent(),
                Value<String?> resolvedBy = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TopoHazardRowsCompanion(
                id: id,
                wallId: wallId,
                routeId: routeId,
                authorId: authorId,
                severity: severity,
                body: body,
                resolvedAt: resolvedAt,
                resolvedBy: resolvedBy,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String wallId,
                Value<String?> routeId = const Value.absent(),
                required String authorId,
                required String severity,
                required String body,
                Value<int?> resolvedAt = const Value.absent(),
                Value<String?> resolvedBy = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => TopoHazardRowsCompanion.insert(
                id: id,
                wallId: wallId,
                routeId: routeId,
                authorId: authorId,
                severity: severity,
                body: body,
                resolvedAt: resolvedAt,
                resolvedBy: resolvedBy,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TopoHazardRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TopoHazardRowsTable,
      TopoHazardRow,
      $$TopoHazardRowsTableFilterComposer,
      $$TopoHazardRowsTableOrderingComposer,
      $$TopoHazardRowsTableAnnotationComposer,
      $$TopoHazardRowsTableCreateCompanionBuilder,
      $$TopoHazardRowsTableUpdateCompanionBuilder,
      (
        TopoHazardRow,
        BaseReferences<_$AppDatabase, $TopoHazardRowsTable, TopoHazardRow>,
      ),
      TopoHazardRow,
      PrefetchHooks Function()
    >;
typedef $$NotificationRowsTableCreateCompanionBuilder =
    NotificationRowsCompanion Function({
      required String id,
      required String recipientId,
      required String kind,
      Value<String?> actorId,
      Value<String?> wallId,
      Value<String?> ascentId,
      Value<String?> commentId,
      Value<String?> preview,
      required int createdAt,
      Value<int?> readAt,
      Value<int> rowid,
    });
typedef $$NotificationRowsTableUpdateCompanionBuilder =
    NotificationRowsCompanion Function({
      Value<String> id,
      Value<String> recipientId,
      Value<String> kind,
      Value<String?> actorId,
      Value<String?> wallId,
      Value<String?> ascentId,
      Value<String?> commentId,
      Value<String?> preview,
      Value<int> createdAt,
      Value<int?> readAt,
      Value<int> rowid,
    });

class $$NotificationRowsTableFilterComposer
    extends Composer<_$AppDatabase, $NotificationRowsTable> {
  $$NotificationRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recipientId => $composableBuilder(
    column: $table.recipientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actorId => $composableBuilder(
    column: $table.actorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ascentId => $composableBuilder(
    column: $table.ascentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get commentId => $composableBuilder(
    column: $table.commentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get preview => $composableBuilder(
    column: $table.preview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get readAt => $composableBuilder(
    column: $table.readAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotificationRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $NotificationRowsTable> {
  $$NotificationRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recipientId => $composableBuilder(
    column: $table.recipientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actorId => $composableBuilder(
    column: $table.actorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wallId => $composableBuilder(
    column: $table.wallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ascentId => $composableBuilder(
    column: $table.ascentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get commentId => $composableBuilder(
    column: $table.commentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get preview => $composableBuilder(
    column: $table.preview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get readAt => $composableBuilder(
    column: $table.readAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotificationRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotificationRowsTable> {
  $$NotificationRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get recipientId => $composableBuilder(
    column: $table.recipientId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get actorId =>
      $composableBuilder(column: $table.actorId, builder: (column) => column);

  GeneratedColumn<String> get wallId =>
      $composableBuilder(column: $table.wallId, builder: (column) => column);

  GeneratedColumn<String> get ascentId =>
      $composableBuilder(column: $table.ascentId, builder: (column) => column);

  GeneratedColumn<String> get commentId =>
      $composableBuilder(column: $table.commentId, builder: (column) => column);

  GeneratedColumn<String> get preview =>
      $composableBuilder(column: $table.preview, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get readAt =>
      $composableBuilder(column: $table.readAt, builder: (column) => column);
}

class $$NotificationRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotificationRowsTable,
          NotificationRow,
          $$NotificationRowsTableFilterComposer,
          $$NotificationRowsTableOrderingComposer,
          $$NotificationRowsTableAnnotationComposer,
          $$NotificationRowsTableCreateCompanionBuilder,
          $$NotificationRowsTableUpdateCompanionBuilder,
          (
            NotificationRow,
            BaseReferences<
              _$AppDatabase,
              $NotificationRowsTable,
              NotificationRow
            >,
          ),
          NotificationRow,
          PrefetchHooks Function()
        > {
  $$NotificationRowsTableTableManager(
    _$AppDatabase db,
    $NotificationRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotificationRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotificationRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotificationRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> recipientId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> actorId = const Value.absent(),
                Value<String?> wallId = const Value.absent(),
                Value<String?> ascentId = const Value.absent(),
                Value<String?> commentId = const Value.absent(),
                Value<String?> preview = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> readAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationRowsCompanion(
                id: id,
                recipientId: recipientId,
                kind: kind,
                actorId: actorId,
                wallId: wallId,
                ascentId: ascentId,
                commentId: commentId,
                preview: preview,
                createdAt: createdAt,
                readAt: readAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String recipientId,
                required String kind,
                Value<String?> actorId = const Value.absent(),
                Value<String?> wallId = const Value.absent(),
                Value<String?> ascentId = const Value.absent(),
                Value<String?> commentId = const Value.absent(),
                Value<String?> preview = const Value.absent(),
                required int createdAt,
                Value<int?> readAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationRowsCompanion.insert(
                id: id,
                recipientId: recipientId,
                kind: kind,
                actorId: actorId,
                wallId: wallId,
                ascentId: ascentId,
                commentId: commentId,
                preview: preview,
                createdAt: createdAt,
                readAt: readAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotificationRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotificationRowsTable,
      NotificationRow,
      $$NotificationRowsTableFilterComposer,
      $$NotificationRowsTableOrderingComposer,
      $$NotificationRowsTableAnnotationComposer,
      $$NotificationRowsTableCreateCompanionBuilder,
      $$NotificationRowsTableUpdateCompanionBuilder,
      (
        NotificationRow,
        BaseReferences<_$AppDatabase, $NotificationRowsTable, NotificationRow>,
      ),
      NotificationRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AreasTableTableManager get areas =>
      $$AreasTableTableManager(_db, _db.areas);
  $$SectorsTableTableManager get sectors =>
      $$SectorsTableTableManager(_db, _db.sectors);
  $$WallsTableTableManager get walls =>
      $$WallsTableTableManager(_db, _db.walls);
  $$PhotosTableTableManager get photos =>
      $$PhotosTableTableManager(_db, _db.photos);
  $$RoutesTableTableManager get routes =>
      $$RoutesTableTableManager(_db, _db.routes);
  $$RouteLinesTableTableManager get routeLines =>
      $$RouteLinesTableTableManager(_db, _db.routeLines);
  $$AscentsTableTableManager get ascents =>
      $$AscentsTableTableManager(_db, _db.ascents);
  $$CommentsTableTableManager get comments =>
      $$CommentsTableTableManager(_db, _db.comments);
  $$LikesTableTableManager get likes =>
      $$LikesTableTableManager(_db, _db.likes);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
  $$WallModerationRowsTableTableManager get wallModerationRows =>
      $$WallModerationRowsTableTableManager(_db, _db.wallModerationRows);
  $$GradeOpinionRowsTableTableManager get gradeOpinionRows =>
      $$GradeOpinionRowsTableTableManager(_db, _db.gradeOpinionRows);
  $$TopoVerificationRowsTableTableManager get topoVerificationRows =>
      $$TopoVerificationRowsTableTableManager(_db, _db.topoVerificationRows);
  $$TopoHazardRowsTableTableManager get topoHazardRows =>
      $$TopoHazardRowsTableTableManager(_db, _db.topoHazardRows);
  $$NotificationRowsTableTableManager get notificationRows =>
      $$NotificationRowsTableTableManager(_db, _db.notificationRows);
}
