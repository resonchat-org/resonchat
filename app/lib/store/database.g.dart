// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ChatsTable extends Chats with TableInfo<$ChatsTable, Chat> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _jidMeta = const VerificationMeta('jid');
  @override
  late final GeneratedColumn<String> jid = GeneratedColumn<String>(
    'jid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lastActivityMeta = const VerificationMeta(
    'lastActivity',
  );
  @override
  late final GeneratedColumn<DateTime> lastActivity = GeneratedColumn<DateTime>(
    'last_activity',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _trackOverrideMeta = const VerificationMeta(
    'trackOverride',
  );
  @override
  late final GeneratedColumn<String> trackOverride = GeneratedColumn<String>(
    'track_override',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    jid,
    title,
    lastActivity,
    trackOverride,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chats';
  @override
  VerificationContext validateIntegrity(
    Insertable<Chat> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('jid')) {
      context.handle(
        _jidMeta,
        jid.isAcceptableOrUnknown(data['jid']!, _jidMeta),
      );
    } else if (isInserting) {
      context.missing(_jidMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('last_activity')) {
      context.handle(
        _lastActivityMeta,
        lastActivity.isAcceptableOrUnknown(
          data['last_activity']!,
          _lastActivityMeta,
        ),
      );
    }
    if (data.containsKey('track_override')) {
      context.handle(
        _trackOverrideMeta,
        trackOverride.isAcceptableOrUnknown(
          data['track_override']!,
          _trackOverrideMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {jid};
  @override
  Chat map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Chat(
      jid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}jid'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      lastActivity: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_activity'],
      )!,
      trackOverride: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}track_override'],
      )!,
    );
  }

  @override
  $ChatsTable createAlias(String alias) {
    return $ChatsTable(attachedDatabase, alias);
  }
}

class Chat extends DataClass implements Insertable<Chat> {
  final String jid;
  final String title;
  final DateTime lastActivity;

  /// The track the user picked for this conversation, or empty for "use the
  /// global default" (docs/10 §3).
  ///
  /// Deliberately not a foreign key to a settings table: the choice is about
  /// this conversation, and the default is a fallback the row simply does not
  /// override. Null also means "never chosen", which is what keeps a fresh
  /// install on the standard track instead of silently inheriting whatever a
  /// previous conversation was set to.
  final String trackOverride;
  const Chat({
    required this.jid,
    required this.title,
    required this.lastActivity,
    required this.trackOverride,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['jid'] = Variable<String>(jid);
    map['title'] = Variable<String>(title);
    map['last_activity'] = Variable<DateTime>(lastActivity);
    map['track_override'] = Variable<String>(trackOverride);
    return map;
  }

  ChatsCompanion toCompanion(bool nullToAbsent) {
    return ChatsCompanion(
      jid: Value(jid),
      title: Value(title),
      lastActivity: Value(lastActivity),
      trackOverride: Value(trackOverride),
    );
  }

  factory Chat.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Chat(
      jid: serializer.fromJson<String>(json['jid']),
      title: serializer.fromJson<String>(json['title']),
      lastActivity: serializer.fromJson<DateTime>(json['lastActivity']),
      trackOverride: serializer.fromJson<String>(json['trackOverride']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'jid': serializer.toJson<String>(jid),
      'title': serializer.toJson<String>(title),
      'lastActivity': serializer.toJson<DateTime>(lastActivity),
      'trackOverride': serializer.toJson<String>(trackOverride),
    };
  }

  Chat copyWith({
    String? jid,
    String? title,
    DateTime? lastActivity,
    String? trackOverride,
  }) => Chat(
    jid: jid ?? this.jid,
    title: title ?? this.title,
    lastActivity: lastActivity ?? this.lastActivity,
    trackOverride: trackOverride ?? this.trackOverride,
  );
  Chat copyWithCompanion(ChatsCompanion data) {
    return Chat(
      jid: data.jid.present ? data.jid.value : this.jid,
      title: data.title.present ? data.title.value : this.title,
      lastActivity: data.lastActivity.present
          ? data.lastActivity.value
          : this.lastActivity,
      trackOverride: data.trackOverride.present
          ? data.trackOverride.value
          : this.trackOverride,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Chat(')
          ..write('jid: $jid, ')
          ..write('title: $title, ')
          ..write('lastActivity: $lastActivity, ')
          ..write('trackOverride: $trackOverride')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(jid, title, lastActivity, trackOverride);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Chat &&
          other.jid == this.jid &&
          other.title == this.title &&
          other.lastActivity == this.lastActivity &&
          other.trackOverride == this.trackOverride);
}

class ChatsCompanion extends UpdateCompanion<Chat> {
  final Value<String> jid;
  final Value<String> title;
  final Value<DateTime> lastActivity;
  final Value<String> trackOverride;
  final Value<int> rowid;
  const ChatsCompanion({
    this.jid = const Value.absent(),
    this.title = const Value.absent(),
    this.lastActivity = const Value.absent(),
    this.trackOverride = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatsCompanion.insert({
    required String jid,
    this.title = const Value.absent(),
    this.lastActivity = const Value.absent(),
    this.trackOverride = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : jid = Value(jid);
  static Insertable<Chat> custom({
    Expression<String>? jid,
    Expression<String>? title,
    Expression<DateTime>? lastActivity,
    Expression<String>? trackOverride,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (jid != null) 'jid': jid,
      if (title != null) 'title': title,
      if (lastActivity != null) 'last_activity': lastActivity,
      if (trackOverride != null) 'track_override': trackOverride,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatsCompanion copyWith({
    Value<String>? jid,
    Value<String>? title,
    Value<DateTime>? lastActivity,
    Value<String>? trackOverride,
    Value<int>? rowid,
  }) {
    return ChatsCompanion(
      jid: jid ?? this.jid,
      title: title ?? this.title,
      lastActivity: lastActivity ?? this.lastActivity,
      trackOverride: trackOverride ?? this.trackOverride,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (jid.present) {
      map['jid'] = Variable<String>(jid.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (lastActivity.present) {
      map['last_activity'] = Variable<DateTime>(lastActivity.value);
    }
    if (trackOverride.present) {
      map['track_override'] = Variable<String>(trackOverride.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatsCompanion(')
          ..write('jid: $jid, ')
          ..write('title: $title, ')
          ..write('lastActivity: $lastActivity, ')
          ..write('trackOverride: $trackOverride, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _chatJidMeta = const VerificationMeta(
    'chatJid',
  );
  @override
  late final GeneratedColumn<String> chatJid = GeneratedColumn<String>(
    'chat_jid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES chats (jid)',
    ),
  );
  static const VerificationMeta _senderMeta = const VerificationMeta('sender');
  @override
  late final GeneratedColumn<String> sender = GeneratedColumn<String>(
    'sender',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stanzaIdMeta = const VerificationMeta(
    'stanzaId',
  );
  @override
  late final GeneratedColumn<String> stanzaId = GeneratedColumn<String>(
    'stanza_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
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
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _encModeMeta = const VerificationMeta(
    'encMode',
  );
  @override
  late final GeneratedColumn<String> encMode = GeneratedColumn<String>(
    'enc_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('none'),
  );
  static const VerificationMeta _incomingMeta = const VerificationMeta(
    'incoming',
  );
  @override
  late final GeneratedColumn<bool> incoming = GeneratedColumn<bool>(
    'incoming',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("incoming" IN (0, 1))',
    ),
  );
  static const VerificationMeta _deliveredMeta = const VerificationMeta(
    'delivered',
  );
  @override
  late final GeneratedColumn<bool> delivered = GeneratedColumn<bool>(
    'delivered',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("delivered" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isCarbonMeta = const VerificationMeta(
    'isCarbon',
  );
  @override
  late final GeneratedColumn<bool> isCarbon = GeneratedColumn<bool>(
    'is_carbon',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_carbon" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deliveryErrorMeta = const VerificationMeta(
    'deliveryError',
  );
  @override
  late final GeneratedColumn<String> deliveryError = GeneratedColumn<String>(
    'delivery_error',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _retractedMeta = const VerificationMeta(
    'retracted',
  );
  @override
  late final GeneratedColumn<bool> retracted = GeneratedColumn<bool>(
    'retracted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("retracted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _retractedAtMeta = const VerificationMeta(
    'retractedAt',
  );
  @override
  late final GeneratedColumn<DateTime> retractedAt = GeneratedColumn<DateTime>(
    'retracted_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _replyToMeta = const VerificationMeta(
    'replyTo',
  );
  @override
  late final GeneratedColumn<String> replyTo = GeneratedColumn<String>(
    'reply_to',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _replyBodyMeta = const VerificationMeta(
    'replyBody',
  );
  @override
  late final GeneratedColumn<String> replyBody = GeneratedColumn<String>(
    'reply_body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _replyAuthorMeta = const VerificationMeta(
    'replyAuthor',
  );
  @override
  late final GeneratedColumn<String> replyAuthor = GeneratedColumn<String>(
    'reply_author',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _editedAtMeta = const VerificationMeta(
    'editedAt',
  );
  @override
  late final GeneratedColumn<DateTime> editedAt = GeneratedColumn<DateTime>(
    'edited_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    chatJid,
    sender,
    stanzaId,
    body,
    timestamp,
    encMode,
    incoming,
    delivered,
    isCarbon,
    deliveryError,
    retracted,
    retractedAt,
    replyTo,
    replyBody,
    replyAuthor,
    editedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<Message> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('chat_jid')) {
      context.handle(
        _chatJidMeta,
        chatJid.isAcceptableOrUnknown(data['chat_jid']!, _chatJidMeta),
      );
    } else if (isInserting) {
      context.missing(_chatJidMeta);
    }
    if (data.containsKey('sender')) {
      context.handle(
        _senderMeta,
        sender.isAcceptableOrUnknown(data['sender']!, _senderMeta),
      );
    } else if (isInserting) {
      context.missing(_senderMeta);
    }
    if (data.containsKey('stanza_id')) {
      context.handle(
        _stanzaIdMeta,
        stanzaId.isAcceptableOrUnknown(data['stanza_id']!, _stanzaIdMeta),
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
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    }
    if (data.containsKey('enc_mode')) {
      context.handle(
        _encModeMeta,
        encMode.isAcceptableOrUnknown(data['enc_mode']!, _encModeMeta),
      );
    }
    if (data.containsKey('incoming')) {
      context.handle(
        _incomingMeta,
        incoming.isAcceptableOrUnknown(data['incoming']!, _incomingMeta),
      );
    } else if (isInserting) {
      context.missing(_incomingMeta);
    }
    if (data.containsKey('delivered')) {
      context.handle(
        _deliveredMeta,
        delivered.isAcceptableOrUnknown(data['delivered']!, _deliveredMeta),
      );
    }
    if (data.containsKey('is_carbon')) {
      context.handle(
        _isCarbonMeta,
        isCarbon.isAcceptableOrUnknown(data['is_carbon']!, _isCarbonMeta),
      );
    }
    if (data.containsKey('delivery_error')) {
      context.handle(
        _deliveryErrorMeta,
        deliveryError.isAcceptableOrUnknown(
          data['delivery_error']!,
          _deliveryErrorMeta,
        ),
      );
    }
    if (data.containsKey('retracted')) {
      context.handle(
        _retractedMeta,
        retracted.isAcceptableOrUnknown(data['retracted']!, _retractedMeta),
      );
    }
    if (data.containsKey('retracted_at')) {
      context.handle(
        _retractedAtMeta,
        retractedAt.isAcceptableOrUnknown(
          data['retracted_at']!,
          _retractedAtMeta,
        ),
      );
    }
    if (data.containsKey('reply_to')) {
      context.handle(
        _replyToMeta,
        replyTo.isAcceptableOrUnknown(data['reply_to']!, _replyToMeta),
      );
    }
    if (data.containsKey('reply_body')) {
      context.handle(
        _replyBodyMeta,
        replyBody.isAcceptableOrUnknown(data['reply_body']!, _replyBodyMeta),
      );
    }
    if (data.containsKey('reply_author')) {
      context.handle(
        _replyAuthorMeta,
        replyAuthor.isAcceptableOrUnknown(
          data['reply_author']!,
          _replyAuthorMeta,
        ),
      );
    }
    if (data.containsKey('edited_at')) {
      context.handle(
        _editedAtMeta,
        editedAt.isAcceptableOrUnknown(data['edited_at']!, _editedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      chatJid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_jid'],
      )!,
      sender: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender'],
      )!,
      stanzaId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stanza_id'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}timestamp'],
      )!,
      encMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}enc_mode'],
      )!,
      incoming: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}incoming'],
      )!,
      delivered: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}delivered'],
      )!,
      isCarbon: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_carbon'],
      )!,
      deliveryError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delivery_error'],
      )!,
      retracted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}retracted'],
      )!,
      retractedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}retracted_at'],
      )!,
      replyTo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_to'],
      )!,
      replyBody: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_body'],
      )!,
      replyAuthor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_author'],
      )!,
      editedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}edited_at'],
      ),
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class Message extends DataClass implements Insertable<Message> {
  final int id;
  final String chatJid;
  final String sender;

  /// Stanza id, used to match XEP-0184 delivery receipts.
  final String stanzaId;
  final String body;
  final DateTime timestamp;
  final String encMode;
  final bool incoming;

  /// False until a delivery receipt arrives (XEP-0184).
  final bool delivered;

  /// Set when this message came from another of our own devices
  /// (XEP-0280 carbon), so the UI can avoid a duplicate bubble.
  final bool isCarbon;

  /// Why the server refused this message, empty when nothing went wrong.
  ///
  /// A message that comes back as `<message type='error'/>` was never
  /// delivered. Showing it as an ordinary outgoing bubble is a lie: the
  /// usual causes are a server service policy, a non-mutual subscription, or
  /// a blocked account, and each needs a different thing from the user.
  final String deliveryError;

  /// True once the sender retracted this message for everyone (XEP-0424).
  ///
  /// The body is kept rather than cleared. Clearing it would look identical to
  /// the message having been encrypted and unreadable, and the two need
  /// different words — and it would make "show the message anyway" impossible
  /// for the person who sent it.
  final bool retracted;

  /// When the retraction arrived, for ordering the "deleted" placeholder.
  final DateTime retractedAt;

  /// Origin-id of the message this one replies to (XEP-0461), or empty.
  final String replyTo;

  /// The quoted text, copied into this row.
  ///
  /// Denormalised on purpose. A quote is only useful if it still reads
  /// correctly after the quoted message is deleted, retracted, or simply never
  /// loaded — and the quoted message is the thing most likely to disappear,
  /// since retracting it is a normal thing to do. Re-reading it from the target
  /// row means a reply turns into an empty quote the moment its target goes.
  final String replyBody;

  /// Nickname of the quoted message's author, for the same reason.
  final String replyAuthor;

  /// Set once this message was corrected (XEP-0308).
  ///
  /// Null for an uncorrected message so "edited" is only claimed when it
  /// happened; a boolean defaulting to false cannot tell "not edited" from
  /// "edited and we lost the flag in a migration".
  final DateTime? editedAt;
  const Message({
    required this.id,
    required this.chatJid,
    required this.sender,
    required this.stanzaId,
    required this.body,
    required this.timestamp,
    required this.encMode,
    required this.incoming,
    required this.delivered,
    required this.isCarbon,
    required this.deliveryError,
    required this.retracted,
    required this.retractedAt,
    required this.replyTo,
    required this.replyBody,
    required this.replyAuthor,
    this.editedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['chat_jid'] = Variable<String>(chatJid);
    map['sender'] = Variable<String>(sender);
    map['stanza_id'] = Variable<String>(stanzaId);
    map['body'] = Variable<String>(body);
    map['timestamp'] = Variable<DateTime>(timestamp);
    map['enc_mode'] = Variable<String>(encMode);
    map['incoming'] = Variable<bool>(incoming);
    map['delivered'] = Variable<bool>(delivered);
    map['is_carbon'] = Variable<bool>(isCarbon);
    map['delivery_error'] = Variable<String>(deliveryError);
    map['retracted'] = Variable<bool>(retracted);
    map['retracted_at'] = Variable<DateTime>(retractedAt);
    map['reply_to'] = Variable<String>(replyTo);
    map['reply_body'] = Variable<String>(replyBody);
    map['reply_author'] = Variable<String>(replyAuthor);
    if (!nullToAbsent || editedAt != null) {
      map['edited_at'] = Variable<DateTime>(editedAt);
    }
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      chatJid: Value(chatJid),
      sender: Value(sender),
      stanzaId: Value(stanzaId),
      body: Value(body),
      timestamp: Value(timestamp),
      encMode: Value(encMode),
      incoming: Value(incoming),
      delivered: Value(delivered),
      isCarbon: Value(isCarbon),
      deliveryError: Value(deliveryError),
      retracted: Value(retracted),
      retractedAt: Value(retractedAt),
      replyTo: Value(replyTo),
      replyBody: Value(replyBody),
      replyAuthor: Value(replyAuthor),
      editedAt: editedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(editedAt),
    );
  }

  factory Message.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      id: serializer.fromJson<int>(json['id']),
      chatJid: serializer.fromJson<String>(json['chatJid']),
      sender: serializer.fromJson<String>(json['sender']),
      stanzaId: serializer.fromJson<String>(json['stanzaId']),
      body: serializer.fromJson<String>(json['body']),
      timestamp: serializer.fromJson<DateTime>(json['timestamp']),
      encMode: serializer.fromJson<String>(json['encMode']),
      incoming: serializer.fromJson<bool>(json['incoming']),
      delivered: serializer.fromJson<bool>(json['delivered']),
      isCarbon: serializer.fromJson<bool>(json['isCarbon']),
      deliveryError: serializer.fromJson<String>(json['deliveryError']),
      retracted: serializer.fromJson<bool>(json['retracted']),
      retractedAt: serializer.fromJson<DateTime>(json['retractedAt']),
      replyTo: serializer.fromJson<String>(json['replyTo']),
      replyBody: serializer.fromJson<String>(json['replyBody']),
      replyAuthor: serializer.fromJson<String>(json['replyAuthor']),
      editedAt: serializer.fromJson<DateTime?>(json['editedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'chatJid': serializer.toJson<String>(chatJid),
      'sender': serializer.toJson<String>(sender),
      'stanzaId': serializer.toJson<String>(stanzaId),
      'body': serializer.toJson<String>(body),
      'timestamp': serializer.toJson<DateTime>(timestamp),
      'encMode': serializer.toJson<String>(encMode),
      'incoming': serializer.toJson<bool>(incoming),
      'delivered': serializer.toJson<bool>(delivered),
      'isCarbon': serializer.toJson<bool>(isCarbon),
      'deliveryError': serializer.toJson<String>(deliveryError),
      'retracted': serializer.toJson<bool>(retracted),
      'retractedAt': serializer.toJson<DateTime>(retractedAt),
      'replyTo': serializer.toJson<String>(replyTo),
      'replyBody': serializer.toJson<String>(replyBody),
      'replyAuthor': serializer.toJson<String>(replyAuthor),
      'editedAt': serializer.toJson<DateTime?>(editedAt),
    };
  }

  Message copyWith({
    int? id,
    String? chatJid,
    String? sender,
    String? stanzaId,
    String? body,
    DateTime? timestamp,
    String? encMode,
    bool? incoming,
    bool? delivered,
    bool? isCarbon,
    String? deliveryError,
    bool? retracted,
    DateTime? retractedAt,
    String? replyTo,
    String? replyBody,
    String? replyAuthor,
    Value<DateTime?> editedAt = const Value.absent(),
  }) => Message(
    id: id ?? this.id,
    chatJid: chatJid ?? this.chatJid,
    sender: sender ?? this.sender,
    stanzaId: stanzaId ?? this.stanzaId,
    body: body ?? this.body,
    timestamp: timestamp ?? this.timestamp,
    encMode: encMode ?? this.encMode,
    incoming: incoming ?? this.incoming,
    delivered: delivered ?? this.delivered,
    isCarbon: isCarbon ?? this.isCarbon,
    deliveryError: deliveryError ?? this.deliveryError,
    retracted: retracted ?? this.retracted,
    retractedAt: retractedAt ?? this.retractedAt,
    replyTo: replyTo ?? this.replyTo,
    replyBody: replyBody ?? this.replyBody,
    replyAuthor: replyAuthor ?? this.replyAuthor,
    editedAt: editedAt.present ? editedAt.value : this.editedAt,
  );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      id: data.id.present ? data.id.value : this.id,
      chatJid: data.chatJid.present ? data.chatJid.value : this.chatJid,
      sender: data.sender.present ? data.sender.value : this.sender,
      stanzaId: data.stanzaId.present ? data.stanzaId.value : this.stanzaId,
      body: data.body.present ? data.body.value : this.body,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      encMode: data.encMode.present ? data.encMode.value : this.encMode,
      incoming: data.incoming.present ? data.incoming.value : this.incoming,
      delivered: data.delivered.present ? data.delivered.value : this.delivered,
      isCarbon: data.isCarbon.present ? data.isCarbon.value : this.isCarbon,
      deliveryError: data.deliveryError.present
          ? data.deliveryError.value
          : this.deliveryError,
      retracted: data.retracted.present ? data.retracted.value : this.retracted,
      retractedAt: data.retractedAt.present
          ? data.retractedAt.value
          : this.retractedAt,
      replyTo: data.replyTo.present ? data.replyTo.value : this.replyTo,
      replyBody: data.replyBody.present ? data.replyBody.value : this.replyBody,
      replyAuthor: data.replyAuthor.present
          ? data.replyAuthor.value
          : this.replyAuthor,
      editedAt: data.editedAt.present ? data.editedAt.value : this.editedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('id: $id, ')
          ..write('chatJid: $chatJid, ')
          ..write('sender: $sender, ')
          ..write('stanzaId: $stanzaId, ')
          ..write('body: $body, ')
          ..write('timestamp: $timestamp, ')
          ..write('encMode: $encMode, ')
          ..write('incoming: $incoming, ')
          ..write('delivered: $delivered, ')
          ..write('isCarbon: $isCarbon, ')
          ..write('deliveryError: $deliveryError, ')
          ..write('retracted: $retracted, ')
          ..write('retractedAt: $retractedAt, ')
          ..write('replyTo: $replyTo, ')
          ..write('replyBody: $replyBody, ')
          ..write('replyAuthor: $replyAuthor, ')
          ..write('editedAt: $editedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    chatJid,
    sender,
    stanzaId,
    body,
    timestamp,
    encMode,
    incoming,
    delivered,
    isCarbon,
    deliveryError,
    retracted,
    retractedAt,
    replyTo,
    replyBody,
    replyAuthor,
    editedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.chatJid == this.chatJid &&
          other.sender == this.sender &&
          other.stanzaId == this.stanzaId &&
          other.body == this.body &&
          other.timestamp == this.timestamp &&
          other.encMode == this.encMode &&
          other.incoming == this.incoming &&
          other.delivered == this.delivered &&
          other.isCarbon == this.isCarbon &&
          other.deliveryError == this.deliveryError &&
          other.retracted == this.retracted &&
          other.retractedAt == this.retractedAt &&
          other.replyTo == this.replyTo &&
          other.replyBody == this.replyBody &&
          other.replyAuthor == this.replyAuthor &&
          other.editedAt == this.editedAt);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<int> id;
  final Value<String> chatJid;
  final Value<String> sender;
  final Value<String> stanzaId;
  final Value<String> body;
  final Value<DateTime> timestamp;
  final Value<String> encMode;
  final Value<bool> incoming;
  final Value<bool> delivered;
  final Value<bool> isCarbon;
  final Value<String> deliveryError;
  final Value<bool> retracted;
  final Value<DateTime> retractedAt;
  final Value<String> replyTo;
  final Value<String> replyBody;
  final Value<String> replyAuthor;
  final Value<DateTime?> editedAt;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.chatJid = const Value.absent(),
    this.sender = const Value.absent(),
    this.stanzaId = const Value.absent(),
    this.body = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.encMode = const Value.absent(),
    this.incoming = const Value.absent(),
    this.delivered = const Value.absent(),
    this.isCarbon = const Value.absent(),
    this.deliveryError = const Value.absent(),
    this.retracted = const Value.absent(),
    this.retractedAt = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.replyBody = const Value.absent(),
    this.replyAuthor = const Value.absent(),
    this.editedAt = const Value.absent(),
  });
  MessagesCompanion.insert({
    this.id = const Value.absent(),
    required String chatJid,
    required String sender,
    this.stanzaId = const Value.absent(),
    required String body,
    this.timestamp = const Value.absent(),
    this.encMode = const Value.absent(),
    required bool incoming,
    this.delivered = const Value.absent(),
    this.isCarbon = const Value.absent(),
    this.deliveryError = const Value.absent(),
    this.retracted = const Value.absent(),
    this.retractedAt = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.replyBody = const Value.absent(),
    this.replyAuthor = const Value.absent(),
    this.editedAt = const Value.absent(),
  }) : chatJid = Value(chatJid),
       sender = Value(sender),
       body = Value(body),
       incoming = Value(incoming);
  static Insertable<Message> custom({
    Expression<int>? id,
    Expression<String>? chatJid,
    Expression<String>? sender,
    Expression<String>? stanzaId,
    Expression<String>? body,
    Expression<DateTime>? timestamp,
    Expression<String>? encMode,
    Expression<bool>? incoming,
    Expression<bool>? delivered,
    Expression<bool>? isCarbon,
    Expression<String>? deliveryError,
    Expression<bool>? retracted,
    Expression<DateTime>? retractedAt,
    Expression<String>? replyTo,
    Expression<String>? replyBody,
    Expression<String>? replyAuthor,
    Expression<DateTime>? editedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (chatJid != null) 'chat_jid': chatJid,
      if (sender != null) 'sender': sender,
      if (stanzaId != null) 'stanza_id': stanzaId,
      if (body != null) 'body': body,
      if (timestamp != null) 'timestamp': timestamp,
      if (encMode != null) 'enc_mode': encMode,
      if (incoming != null) 'incoming': incoming,
      if (delivered != null) 'delivered': delivered,
      if (isCarbon != null) 'is_carbon': isCarbon,
      if (deliveryError != null) 'delivery_error': deliveryError,
      if (retracted != null) 'retracted': retracted,
      if (retractedAt != null) 'retracted_at': retractedAt,
      if (replyTo != null) 'reply_to': replyTo,
      if (replyBody != null) 'reply_body': replyBody,
      if (replyAuthor != null) 'reply_author': replyAuthor,
      if (editedAt != null) 'edited_at': editedAt,
    });
  }

  MessagesCompanion copyWith({
    Value<int>? id,
    Value<String>? chatJid,
    Value<String>? sender,
    Value<String>? stanzaId,
    Value<String>? body,
    Value<DateTime>? timestamp,
    Value<String>? encMode,
    Value<bool>? incoming,
    Value<bool>? delivered,
    Value<bool>? isCarbon,
    Value<String>? deliveryError,
    Value<bool>? retracted,
    Value<DateTime>? retractedAt,
    Value<String>? replyTo,
    Value<String>? replyBody,
    Value<String>? replyAuthor,
    Value<DateTime?>? editedAt,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      chatJid: chatJid ?? this.chatJid,
      sender: sender ?? this.sender,
      stanzaId: stanzaId ?? this.stanzaId,
      body: body ?? this.body,
      timestamp: timestamp ?? this.timestamp,
      encMode: encMode ?? this.encMode,
      incoming: incoming ?? this.incoming,
      delivered: delivered ?? this.delivered,
      isCarbon: isCarbon ?? this.isCarbon,
      deliveryError: deliveryError ?? this.deliveryError,
      retracted: retracted ?? this.retracted,
      retractedAt: retractedAt ?? this.retractedAt,
      replyTo: replyTo ?? this.replyTo,
      replyBody: replyBody ?? this.replyBody,
      replyAuthor: replyAuthor ?? this.replyAuthor,
      editedAt: editedAt ?? this.editedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (chatJid.present) {
      map['chat_jid'] = Variable<String>(chatJid.value);
    }
    if (sender.present) {
      map['sender'] = Variable<String>(sender.value);
    }
    if (stanzaId.present) {
      map['stanza_id'] = Variable<String>(stanzaId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (encMode.present) {
      map['enc_mode'] = Variable<String>(encMode.value);
    }
    if (incoming.present) {
      map['incoming'] = Variable<bool>(incoming.value);
    }
    if (delivered.present) {
      map['delivered'] = Variable<bool>(delivered.value);
    }
    if (isCarbon.present) {
      map['is_carbon'] = Variable<bool>(isCarbon.value);
    }
    if (deliveryError.present) {
      map['delivery_error'] = Variable<String>(deliveryError.value);
    }
    if (retracted.present) {
      map['retracted'] = Variable<bool>(retracted.value);
    }
    if (retractedAt.present) {
      map['retracted_at'] = Variable<DateTime>(retractedAt.value);
    }
    if (replyTo.present) {
      map['reply_to'] = Variable<String>(replyTo.value);
    }
    if (replyBody.present) {
      map['reply_body'] = Variable<String>(replyBody.value);
    }
    if (replyAuthor.present) {
      map['reply_author'] = Variable<String>(replyAuthor.value);
    }
    if (editedAt.present) {
      map['edited_at'] = Variable<DateTime>(editedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('chatJid: $chatJid, ')
          ..write('sender: $sender, ')
          ..write('stanzaId: $stanzaId, ')
          ..write('body: $body, ')
          ..write('timestamp: $timestamp, ')
          ..write('encMode: $encMode, ')
          ..write('incoming: $incoming, ')
          ..write('delivered: $delivered, ')
          ..write('isCarbon: $isCarbon, ')
          ..write('deliveryError: $deliveryError, ')
          ..write('retracted: $retracted, ')
          ..write('retractedAt: $retractedAt, ')
          ..write('replyTo: $replyTo, ')
          ..write('replyBody: $replyBody, ')
          ..write('replyAuthor: $replyAuthor, ')
          ..write('editedAt: $editedAt')
          ..write(')'))
        .toString();
  }
}

class $RosterEntriesTable extends RosterEntries
    with TableInfo<$RosterEntriesTable, RosterEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RosterEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _jidMeta = const VerificationMeta('jid');
  @override
  late final GeneratedColumn<String> jid = GeneratedColumn<String>(
    'jid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _subscriptionMeta = const VerificationMeta(
    'subscription',
  );
  @override
  late final GeneratedColumn<String> subscription = GeneratedColumn<String>(
    'subscription',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('none'),
  );
  static const VerificationMeta _askMeta = const VerificationMeta('ask');
  @override
  late final GeneratedColumn<String> ask = GeneratedColumn<String>(
    'ask',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _groupsMeta = const VerificationMeta('groups');
  @override
  late final GeneratedColumn<String> groups = GeneratedColumn<String>(
    'groups',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [jid, name, subscription, ask, groups];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'roster_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<RosterEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('jid')) {
      context.handle(
        _jidMeta,
        jid.isAcceptableOrUnknown(data['jid']!, _jidMeta),
      );
    } else if (isInserting) {
      context.missing(_jidMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('subscription')) {
      context.handle(
        _subscriptionMeta,
        subscription.isAcceptableOrUnknown(
          data['subscription']!,
          _subscriptionMeta,
        ),
      );
    }
    if (data.containsKey('ask')) {
      context.handle(
        _askMeta,
        ask.isAcceptableOrUnknown(data['ask']!, _askMeta),
      );
    }
    if (data.containsKey('groups')) {
      context.handle(
        _groupsMeta,
        groups.isAcceptableOrUnknown(data['groups']!, _groupsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {jid};
  @override
  RosterEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RosterEntry(
      jid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}jid'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      subscription: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subscription'],
      )!,
      ask: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ask'],
      )!,
      groups: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}groups'],
      )!,
    );
  }

  @override
  $RosterEntriesTable createAlias(String alias) {
    return $RosterEntriesTable(attachedDatabase, alias);
  }
}

class RosterEntry extends DataClass implements Insertable<RosterEntry> {
  final String jid;
  final String name;
  final String subscription;
  final String ask;
  final String groups;
  const RosterEntry({
    required this.jid,
    required this.name,
    required this.subscription,
    required this.ask,
    required this.groups,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['jid'] = Variable<String>(jid);
    map['name'] = Variable<String>(name);
    map['subscription'] = Variable<String>(subscription);
    map['ask'] = Variable<String>(ask);
    map['groups'] = Variable<String>(groups);
    return map;
  }

  RosterEntriesCompanion toCompanion(bool nullToAbsent) {
    return RosterEntriesCompanion(
      jid: Value(jid),
      name: Value(name),
      subscription: Value(subscription),
      ask: Value(ask),
      groups: Value(groups),
    );
  }

  factory RosterEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RosterEntry(
      jid: serializer.fromJson<String>(json['jid']),
      name: serializer.fromJson<String>(json['name']),
      subscription: serializer.fromJson<String>(json['subscription']),
      ask: serializer.fromJson<String>(json['ask']),
      groups: serializer.fromJson<String>(json['groups']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'jid': serializer.toJson<String>(jid),
      'name': serializer.toJson<String>(name),
      'subscription': serializer.toJson<String>(subscription),
      'ask': serializer.toJson<String>(ask),
      'groups': serializer.toJson<String>(groups),
    };
  }

  RosterEntry copyWith({
    String? jid,
    String? name,
    String? subscription,
    String? ask,
    String? groups,
  }) => RosterEntry(
    jid: jid ?? this.jid,
    name: name ?? this.name,
    subscription: subscription ?? this.subscription,
    ask: ask ?? this.ask,
    groups: groups ?? this.groups,
  );
  RosterEntry copyWithCompanion(RosterEntriesCompanion data) {
    return RosterEntry(
      jid: data.jid.present ? data.jid.value : this.jid,
      name: data.name.present ? data.name.value : this.name,
      subscription: data.subscription.present
          ? data.subscription.value
          : this.subscription,
      ask: data.ask.present ? data.ask.value : this.ask,
      groups: data.groups.present ? data.groups.value : this.groups,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RosterEntry(')
          ..write('jid: $jid, ')
          ..write('name: $name, ')
          ..write('subscription: $subscription, ')
          ..write('ask: $ask, ')
          ..write('groups: $groups')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(jid, name, subscription, ask, groups);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RosterEntry &&
          other.jid == this.jid &&
          other.name == this.name &&
          other.subscription == this.subscription &&
          other.ask == this.ask &&
          other.groups == this.groups);
}

class RosterEntriesCompanion extends UpdateCompanion<RosterEntry> {
  final Value<String> jid;
  final Value<String> name;
  final Value<String> subscription;
  final Value<String> ask;
  final Value<String> groups;
  final Value<int> rowid;
  const RosterEntriesCompanion({
    this.jid = const Value.absent(),
    this.name = const Value.absent(),
    this.subscription = const Value.absent(),
    this.ask = const Value.absent(),
    this.groups = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RosterEntriesCompanion.insert({
    required String jid,
    this.name = const Value.absent(),
    this.subscription = const Value.absent(),
    this.ask = const Value.absent(),
    this.groups = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : jid = Value(jid);
  static Insertable<RosterEntry> custom({
    Expression<String>? jid,
    Expression<String>? name,
    Expression<String>? subscription,
    Expression<String>? ask,
    Expression<String>? groups,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (jid != null) 'jid': jid,
      if (name != null) 'name': name,
      if (subscription != null) 'subscription': subscription,
      if (ask != null) 'ask': ask,
      if (groups != null) 'groups': groups,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RosterEntriesCompanion copyWith({
    Value<String>? jid,
    Value<String>? name,
    Value<String>? subscription,
    Value<String>? ask,
    Value<String>? groups,
    Value<int>? rowid,
  }) {
    return RosterEntriesCompanion(
      jid: jid ?? this.jid,
      name: name ?? this.name,
      subscription: subscription ?? this.subscription,
      ask: ask ?? this.ask,
      groups: groups ?? this.groups,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (jid.present) {
      map['jid'] = Variable<String>(jid.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (subscription.present) {
      map['subscription'] = Variable<String>(subscription.value);
    }
    if (ask.present) {
      map['ask'] = Variable<String>(ask.value);
    }
    if (groups.present) {
      map['groups'] = Variable<String>(groups.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RosterEntriesCompanion(')
          ..write('jid: $jid, ')
          ..write('name: $name, ')
          ..write('subscription: $subscription, ')
          ..write('ask: $ask, ')
          ..write('groups: $groups, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingCorrectionsTable extends PendingCorrections
    with TableInfo<$PendingCorrectionsTable, PendingCorrection> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingCorrectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _targetIdMeta = const VerificationMeta(
    'targetId',
  );
  @override
  late final GeneratedColumn<String> targetId = GeneratedColumn<String>(
    'target_id',
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
  static const VerificationMeta _encModeMeta = const VerificationMeta(
    'encMode',
  );
  @override
  late final GeneratedColumn<String> encMode = GeneratedColumn<String>(
    'enc_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('none'),
  );
  static const VerificationMeta _correctedAtMeta = const VerificationMeta(
    'correctedAt',
  );
  @override
  late final GeneratedColumn<DateTime> correctedAt = GeneratedColumn<DateTime>(
    'corrected_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [targetId, body, encMode, correctedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_corrections';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingCorrection> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('target_id')) {
      context.handle(
        _targetIdMeta,
        targetId.isAcceptableOrUnknown(data['target_id']!, _targetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_targetIdMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('enc_mode')) {
      context.handle(
        _encModeMeta,
        encMode.isAcceptableOrUnknown(data['enc_mode']!, _encModeMeta),
      );
    }
    if (data.containsKey('corrected_at')) {
      context.handle(
        _correctedAtMeta,
        correctedAt.isAcceptableOrUnknown(
          data['corrected_at']!,
          _correctedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {targetId};
  @override
  PendingCorrection map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingCorrection(
      targetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_id'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      encMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}enc_mode'],
      )!,
      correctedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}corrected_at'],
      )!,
    );
  }

  @override
  $PendingCorrectionsTable createAlias(String alias) {
    return $PendingCorrectionsTable(attachedDatabase, alias);
  }
}

class PendingCorrection extends DataClass
    implements Insertable<PendingCorrection> {
  final String targetId;
  final String body;
  final String encMode;
  final DateTime correctedAt;
  const PendingCorrection({
    required this.targetId,
    required this.body,
    required this.encMode,
    required this.correctedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['target_id'] = Variable<String>(targetId);
    map['body'] = Variable<String>(body);
    map['enc_mode'] = Variable<String>(encMode);
    map['corrected_at'] = Variable<DateTime>(correctedAt);
    return map;
  }

  PendingCorrectionsCompanion toCompanion(bool nullToAbsent) {
    return PendingCorrectionsCompanion(
      targetId: Value(targetId),
      body: Value(body),
      encMode: Value(encMode),
      correctedAt: Value(correctedAt),
    );
  }

  factory PendingCorrection.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingCorrection(
      targetId: serializer.fromJson<String>(json['targetId']),
      body: serializer.fromJson<String>(json['body']),
      encMode: serializer.fromJson<String>(json['encMode']),
      correctedAt: serializer.fromJson<DateTime>(json['correctedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'targetId': serializer.toJson<String>(targetId),
      'body': serializer.toJson<String>(body),
      'encMode': serializer.toJson<String>(encMode),
      'correctedAt': serializer.toJson<DateTime>(correctedAt),
    };
  }

  PendingCorrection copyWith({
    String? targetId,
    String? body,
    String? encMode,
    DateTime? correctedAt,
  }) => PendingCorrection(
    targetId: targetId ?? this.targetId,
    body: body ?? this.body,
    encMode: encMode ?? this.encMode,
    correctedAt: correctedAt ?? this.correctedAt,
  );
  PendingCorrection copyWithCompanion(PendingCorrectionsCompanion data) {
    return PendingCorrection(
      targetId: data.targetId.present ? data.targetId.value : this.targetId,
      body: data.body.present ? data.body.value : this.body,
      encMode: data.encMode.present ? data.encMode.value : this.encMode,
      correctedAt: data.correctedAt.present
          ? data.correctedAt.value
          : this.correctedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingCorrection(')
          ..write('targetId: $targetId, ')
          ..write('body: $body, ')
          ..write('encMode: $encMode, ')
          ..write('correctedAt: $correctedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(targetId, body, encMode, correctedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingCorrection &&
          other.targetId == this.targetId &&
          other.body == this.body &&
          other.encMode == this.encMode &&
          other.correctedAt == this.correctedAt);
}

class PendingCorrectionsCompanion extends UpdateCompanion<PendingCorrection> {
  final Value<String> targetId;
  final Value<String> body;
  final Value<String> encMode;
  final Value<DateTime> correctedAt;
  final Value<int> rowid;
  const PendingCorrectionsCompanion({
    this.targetId = const Value.absent(),
    this.body = const Value.absent(),
    this.encMode = const Value.absent(),
    this.correctedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingCorrectionsCompanion.insert({
    required String targetId,
    required String body,
    this.encMode = const Value.absent(),
    this.correctedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : targetId = Value(targetId),
       body = Value(body);
  static Insertable<PendingCorrection> custom({
    Expression<String>? targetId,
    Expression<String>? body,
    Expression<String>? encMode,
    Expression<DateTime>? correctedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (targetId != null) 'target_id': targetId,
      if (body != null) 'body': body,
      if (encMode != null) 'enc_mode': encMode,
      if (correctedAt != null) 'corrected_at': correctedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingCorrectionsCompanion copyWith({
    Value<String>? targetId,
    Value<String>? body,
    Value<String>? encMode,
    Value<DateTime>? correctedAt,
    Value<int>? rowid,
  }) {
    return PendingCorrectionsCompanion(
      targetId: targetId ?? this.targetId,
      body: body ?? this.body,
      encMode: encMode ?? this.encMode,
      correctedAt: correctedAt ?? this.correctedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (targetId.present) {
      map['target_id'] = Variable<String>(targetId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (encMode.present) {
      map['enc_mode'] = Variable<String>(encMode.value);
    }
    if (correctedAt.present) {
      map['corrected_at'] = Variable<DateTime>(correctedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingCorrectionsCompanion(')
          ..write('targetId: $targetId, ')
          ..write('body: $body, ')
          ..write('encMode: $encMode, ')
          ..write('correctedAt: $correctedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReactionsTable extends Reactions
    with TableInfo<$ReactionsTable, Reaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _targetIdMeta = const VerificationMeta(
    'targetId',
  );
  @override
  late final GeneratedColumn<String> targetId = GeneratedColumn<String>(
    'target_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emojiMeta = const VerificationMeta('emoji');
  @override
  late final GeneratedColumn<String> emoji = GeneratedColumn<String>(
    'emoji',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reactorMeta = const VerificationMeta(
    'reactor',
  );
  @override
  late final GeneratedColumn<String> reactor = GeneratedColumn<String>(
    'reactor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reactedAtMeta = const VerificationMeta(
    'reactedAt',
  );
  @override
  late final GeneratedColumn<DateTime> reactedAt = GeneratedColumn<DateTime>(
    'reacted_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [targetId, emoji, reactor, reactedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reactions';
  @override
  VerificationContext validateIntegrity(
    Insertable<Reaction> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('target_id')) {
      context.handle(
        _targetIdMeta,
        targetId.isAcceptableOrUnknown(data['target_id']!, _targetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_targetIdMeta);
    }
    if (data.containsKey('emoji')) {
      context.handle(
        _emojiMeta,
        emoji.isAcceptableOrUnknown(data['emoji']!, _emojiMeta),
      );
    } else if (isInserting) {
      context.missing(_emojiMeta);
    }
    if (data.containsKey('reactor')) {
      context.handle(
        _reactorMeta,
        reactor.isAcceptableOrUnknown(data['reactor']!, _reactorMeta),
      );
    } else if (isInserting) {
      context.missing(_reactorMeta);
    }
    if (data.containsKey('reacted_at')) {
      context.handle(
        _reactedAtMeta,
        reactedAt.isAcceptableOrUnknown(data['reacted_at']!, _reactedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {targetId, emoji, reactor};
  @override
  Reaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Reaction(
      targetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_id'],
      )!,
      emoji: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}emoji'],
      )!,
      reactor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reactor'],
      )!,
      reactedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}reacted_at'],
      )!,
    );
  }

  @override
  $ReactionsTable createAlias(String alias) {
    return $ReactionsTable(attachedDatabase, alias);
  }
}

class Reaction extends DataClass implements Insertable<Reaction> {
  final String targetId;

  /// The emoji. Not an icon or a code point: reactions cross clients, so the
  /// value has to be something both ends render the same way.
  final String emoji;

  /// Bare JID of the reactor.
  final String reactor;

  /// When we first saw it; only used for ordering the chip strip.
  final DateTime reactedAt;
  const Reaction({
    required this.targetId,
    required this.emoji,
    required this.reactor,
    required this.reactedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['target_id'] = Variable<String>(targetId);
    map['emoji'] = Variable<String>(emoji);
    map['reactor'] = Variable<String>(reactor);
    map['reacted_at'] = Variable<DateTime>(reactedAt);
    return map;
  }

  ReactionsCompanion toCompanion(bool nullToAbsent) {
    return ReactionsCompanion(
      targetId: Value(targetId),
      emoji: Value(emoji),
      reactor: Value(reactor),
      reactedAt: Value(reactedAt),
    );
  }

  factory Reaction.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Reaction(
      targetId: serializer.fromJson<String>(json['targetId']),
      emoji: serializer.fromJson<String>(json['emoji']),
      reactor: serializer.fromJson<String>(json['reactor']),
      reactedAt: serializer.fromJson<DateTime>(json['reactedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'targetId': serializer.toJson<String>(targetId),
      'emoji': serializer.toJson<String>(emoji),
      'reactor': serializer.toJson<String>(reactor),
      'reactedAt': serializer.toJson<DateTime>(reactedAt),
    };
  }

  Reaction copyWith({
    String? targetId,
    String? emoji,
    String? reactor,
    DateTime? reactedAt,
  }) => Reaction(
    targetId: targetId ?? this.targetId,
    emoji: emoji ?? this.emoji,
    reactor: reactor ?? this.reactor,
    reactedAt: reactedAt ?? this.reactedAt,
  );
  Reaction copyWithCompanion(ReactionsCompanion data) {
    return Reaction(
      targetId: data.targetId.present ? data.targetId.value : this.targetId,
      emoji: data.emoji.present ? data.emoji.value : this.emoji,
      reactor: data.reactor.present ? data.reactor.value : this.reactor,
      reactedAt: data.reactedAt.present ? data.reactedAt.value : this.reactedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Reaction(')
          ..write('targetId: $targetId, ')
          ..write('emoji: $emoji, ')
          ..write('reactor: $reactor, ')
          ..write('reactedAt: $reactedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(targetId, emoji, reactor, reactedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Reaction &&
          other.targetId == this.targetId &&
          other.emoji == this.emoji &&
          other.reactor == this.reactor &&
          other.reactedAt == this.reactedAt);
}

class ReactionsCompanion extends UpdateCompanion<Reaction> {
  final Value<String> targetId;
  final Value<String> emoji;
  final Value<String> reactor;
  final Value<DateTime> reactedAt;
  final Value<int> rowid;
  const ReactionsCompanion({
    this.targetId = const Value.absent(),
    this.emoji = const Value.absent(),
    this.reactor = const Value.absent(),
    this.reactedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReactionsCompanion.insert({
    required String targetId,
    required String emoji,
    required String reactor,
    this.reactedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : targetId = Value(targetId),
       emoji = Value(emoji),
       reactor = Value(reactor);
  static Insertable<Reaction> custom({
    Expression<String>? targetId,
    Expression<String>? emoji,
    Expression<String>? reactor,
    Expression<DateTime>? reactedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (targetId != null) 'target_id': targetId,
      if (emoji != null) 'emoji': emoji,
      if (reactor != null) 'reactor': reactor,
      if (reactedAt != null) 'reacted_at': reactedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReactionsCompanion copyWith({
    Value<String>? targetId,
    Value<String>? emoji,
    Value<String>? reactor,
    Value<DateTime>? reactedAt,
    Value<int>? rowid,
  }) {
    return ReactionsCompanion(
      targetId: targetId ?? this.targetId,
      emoji: emoji ?? this.emoji,
      reactor: reactor ?? this.reactor,
      reactedAt: reactedAt ?? this.reactedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (targetId.present) {
      map['target_id'] = Variable<String>(targetId.value);
    }
    if (emoji.present) {
      map['emoji'] = Variable<String>(emoji.value);
    }
    if (reactor.present) {
      map['reactor'] = Variable<String>(reactor.value);
    }
    if (reactedAt.present) {
      map['reacted_at'] = Variable<DateTime>(reactedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReactionsCompanion(')
          ..write('targetId: $targetId, ')
          ..write('emoji: $emoji, ')
          ..write('reactor: $reactor, ')
          ..write('reactedAt: $reactedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MetaTable extends Meta with TableInfo<$MetaTable, MetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<MetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetaData(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $MetaTable createAlias(String alias) {
    return $MetaTable(attachedDatabase, alias);
  }
}

class MetaData extends DataClass implements Insertable<MetaData> {
  final String key;
  final String value;
  const MetaData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MetaCompanion toCompanion(bool nullToAbsent) {
    return MetaCompanion(key: Value(key), value: Value(value));
  }

  factory MetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetaData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  MetaData copyWith({String? key, String? value}) =>
      MetaData(key: key ?? this.key, value: value ?? this.value);
  MetaData copyWithCompanion(MetaCompanion data) {
    return MetaData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetaData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MetaData && other.key == this.key && other.value == this.value);
}

class MetaCompanion extends UpdateCompanion<MetaData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<MetaData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return MetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ChatsTable chats = $ChatsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $RosterEntriesTable rosterEntries = $RosterEntriesTable(this);
  late final $PendingCorrectionsTable pendingCorrections =
      $PendingCorrectionsTable(this);
  late final $ReactionsTable reactions = $ReactionsTable(this);
  late final $MetaTable meta = $MetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    chats,
    messages,
    rosterEntries,
    pendingCorrections,
    reactions,
    meta,
  ];
}

typedef $$ChatsTableCreateCompanionBuilder = ChatsCompanion Function({
  required String jid,
  Value<String> title,
  Value<DateTime> lastActivity,
  Value<String> trackOverride,
  Value<int> rowid,
});
typedef $$ChatsTableUpdateCompanionBuilder = ChatsCompanion Function({
  Value<String> jid,
  Value<String> title,
  Value<DateTime> lastActivity,
  Value<String> trackOverride,
  Value<int> rowid,
});

final class $$ChatsTableReferences
    extends BaseReferences<_$AppDatabase, $ChatsTable, Chat> {
  $$ChatsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MessagesTable, List<Message>> _messagesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.messages,
    aliasName: 'chats__jid__messages__chat_jid',
  );

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.chatJid.jid.sqlEquals($_itemColumn<String>('jid')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ChatsTableFilterComposer extends Composer<_$AppDatabase, $ChatsTable> {
  $$ChatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get jid => $composableBuilder(
    column: $table.jid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastActivity => $composableBuilder(
    column: $table.lastActivity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get trackOverride => $composableBuilder(
    column: $table.trackOverride,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> messagesRefs(
    Expression<bool> Function($$MessagesTableFilterComposer f) f,
  ) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.jid,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.chatJid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ChatsTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatsTable> {
  $$ChatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get jid => $composableBuilder(
    column: $table.jid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastActivity => $composableBuilder(
    column: $table.lastActivity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get trackOverride => $composableBuilder(
    column: $table.trackOverride,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChatsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatsTable> {
  $$ChatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get jid =>
      $composableBuilder(column: $table.jid, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<DateTime> get lastActivity => $composableBuilder(
    column: $table.lastActivity,
    builder: (column) => column,
  );

  GeneratedColumn<String> get trackOverride => $composableBuilder(
    column: $table.trackOverride,
    builder: (column) => column,
  );

  Expression<T> messagesRefs<T extends Object>(
    Expression<T> Function($$MessagesTableAnnotationComposer a) f,
  ) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.jid,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.chatJid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ChatsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatsTable,
          Chat,
          $$ChatsTableFilterComposer,
          $$ChatsTableOrderingComposer,
          $$ChatsTableAnnotationComposer,
          $$ChatsTableCreateCompanionBuilder,
          $$ChatsTableUpdateCompanionBuilder,
          (Chat, $$ChatsTableReferences),
          Chat,
          PrefetchHooks Function({bool messagesRefs})
        > {
  $$ChatsTableTableManager(_$AppDatabase db, $ChatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> jid = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<DateTime> lastActivity = const Value.absent(),
                Value<String> trackOverride = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChatsCompanion(
                jid: jid,
                title: title,
                lastActivity: lastActivity,
                trackOverride: trackOverride,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String jid,
                Value<String> title = const Value.absent(),
                Value<DateTime> lastActivity = const Value.absent(),
                Value<String> trackOverride = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChatsCompanion.insert(
                jid: jid,
                title: title,
                lastActivity: lastActivity,
                trackOverride: trackOverride,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChatsTable, Chat>(table),
                  $$ChatsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedData<Chat, $ChatsTable, Message>(
                      currentTable: table,
                      referencedTable: $$ChatsTableReferences
                          ._messagesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$ChatsTableReferences(db, table, p0).messagesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.chatJid == item.jid),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ChatsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatsTable,
      Chat,
      $$ChatsTableFilterComposer,
      $$ChatsTableOrderingComposer,
      $$ChatsTableAnnotationComposer,
      $$ChatsTableCreateCompanionBuilder,
      $$ChatsTableUpdateCompanionBuilder,
      (Chat, $$ChatsTableReferences),
      Chat,
      PrefetchHooks Function({bool messagesRefs})
    >;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  Value<int> id,
  required String chatJid,
  required String sender,
  Value<String> stanzaId,
  required String body,
  Value<DateTime> timestamp,
  Value<String> encMode,
  required bool incoming,
  Value<bool> delivered,
  Value<bool> isCarbon,
  Value<String> deliveryError,
  Value<bool> retracted,
  Value<DateTime> retractedAt,
  Value<String> replyTo,
  Value<String> replyBody,
  Value<String> replyAuthor,
  Value<DateTime?> editedAt,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<int> id,
  Value<String> chatJid,
  Value<String> sender,
  Value<String> stanzaId,
  Value<String> body,
  Value<DateTime> timestamp,
  Value<String> encMode,
  Value<bool> incoming,
  Value<bool> delivered,
  Value<bool> isCarbon,
  Value<String> deliveryError,
  Value<bool> retracted,
  Value<DateTime> retractedAt,
  Value<String> replyTo,
  Value<String> replyBody,
  Value<String> replyAuthor,
  Value<DateTime?> editedAt,
});

final class $$MessagesTableReferences
    extends BaseReferences<_$AppDatabase, $MessagesTable, Message> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ChatsTable _chatJidTable(_$AppDatabase db) =>
      db.chats.createAlias('messages__chat_jid__chats__jid');

  $$ChatsTableProcessedTableManager get chatJid {
    final $_column = $_itemColumn<String>('chat_jid')!;

    final manager = $$ChatsTableTableManager(
      $_db,
      $_db.chats,
    ).filter((f) => f.jid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_chatJidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sender => $composableBuilder(
    column: $table.sender,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stanzaId => $composableBuilder(
    column: $table.stanzaId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encMode => $composableBuilder(
    column: $table.encMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get incoming => $composableBuilder(
    column: $table.incoming,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get delivered => $composableBuilder(
    column: $table.delivered,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCarbon => $composableBuilder(
    column: $table.isCarbon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deliveryError => $composableBuilder(
    column: $table.deliveryError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get retracted => $composableBuilder(
    column: $table.retracted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get retractedAt => $composableBuilder(
    column: $table.retractedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyBody => $composableBuilder(
    column: $table.replyBody,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyAuthor => $composableBuilder(
    column: $table.replyAuthor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get editedAt => $composableBuilder(
    column: $table.editedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$ChatsTableFilterComposer get chatJid {
    final $$ChatsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.chatJid,
      referencedTable: $db.chats,
      getReferencedColumn: (t) => t.jid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatsTableFilterComposer(
            $db: $db,
            $table: $db.chats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sender => $composableBuilder(
    column: $table.sender,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stanzaId => $composableBuilder(
    column: $table.stanzaId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encMode => $composableBuilder(
    column: $table.encMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get incoming => $composableBuilder(
    column: $table.incoming,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get delivered => $composableBuilder(
    column: $table.delivered,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCarbon => $composableBuilder(
    column: $table.isCarbon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deliveryError => $composableBuilder(
    column: $table.deliveryError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get retracted => $composableBuilder(
    column: $table.retracted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get retractedAt => $composableBuilder(
    column: $table.retractedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyBody => $composableBuilder(
    column: $table.replyBody,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyAuthor => $composableBuilder(
    column: $table.replyAuthor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get editedAt => $composableBuilder(
    column: $table.editedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$ChatsTableOrderingComposer get chatJid {
    final $$ChatsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.chatJid,
      referencedTable: $db.chats,
      getReferencedColumn: (t) => t.jid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatsTableOrderingComposer(
            $db: $db,
            $table: $db.chats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sender =>
      $composableBuilder(column: $table.sender, builder: (column) => column);

  GeneratedColumn<String> get stanzaId =>
      $composableBuilder(column: $table.stanzaId, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get encMode =>
      $composableBuilder(column: $table.encMode, builder: (column) => column);

  GeneratedColumn<bool> get incoming =>
      $composableBuilder(column: $table.incoming, builder: (column) => column);

  GeneratedColumn<bool> get delivered =>
      $composableBuilder(column: $table.delivered, builder: (column) => column);

  GeneratedColumn<bool> get isCarbon =>
      $composableBuilder(column: $table.isCarbon, builder: (column) => column);

  GeneratedColumn<String> get deliveryError => $composableBuilder(
    column: $table.deliveryError,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get retracted =>
      $composableBuilder(column: $table.retracted, builder: (column) => column);

  GeneratedColumn<DateTime> get retractedAt => $composableBuilder(
    column: $table.retractedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get replyTo =>
      $composableBuilder(column: $table.replyTo, builder: (column) => column);

  GeneratedColumn<String> get replyBody =>
      $composableBuilder(column: $table.replyBody, builder: (column) => column);

  GeneratedColumn<String> get replyAuthor => $composableBuilder(
    column: $table.replyAuthor,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get editedAt =>
      $composableBuilder(column: $table.editedAt, builder: (column) => column);

  $$ChatsTableAnnotationComposer get chatJid {
    final $$ChatsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.chatJid,
      referencedTable: $db.chats,
      getReferencedColumn: (t) => t.jid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatsTableAnnotationComposer(
            $db: $db,
            $table: $db.chats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagesTable,
          Message,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (Message, $$MessagesTableReferences),
          Message,
          PrefetchHooks Function({bool chatJid})
        > {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> chatJid = const Value.absent(),
                Value<String> sender = const Value.absent(),
                Value<String> stanzaId = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<DateTime> timestamp = const Value.absent(),
                Value<String> encMode = const Value.absent(),
                Value<bool> incoming = const Value.absent(),
                Value<bool> delivered = const Value.absent(),
                Value<bool> isCarbon = const Value.absent(),
                Value<String> deliveryError = const Value.absent(),
                Value<bool> retracted = const Value.absent(),
                Value<DateTime> retractedAt = const Value.absent(),
                Value<String> replyTo = const Value.absent(),
                Value<String> replyBody = const Value.absent(),
                Value<String> replyAuthor = const Value.absent(),
                Value<DateTime?> editedAt = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                chatJid: chatJid,
                sender: sender,
                stanzaId: stanzaId,
                body: body,
                timestamp: timestamp,
                encMode: encMode,
                incoming: incoming,
                delivered: delivered,
                isCarbon: isCarbon,
                deliveryError: deliveryError,
                retracted: retracted,
                retractedAt: retractedAt,
                replyTo: replyTo,
                replyBody: replyBody,
                replyAuthor: replyAuthor,
                editedAt: editedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String chatJid,
                required String sender,
                Value<String> stanzaId = const Value.absent(),
                required String body,
                Value<DateTime> timestamp = const Value.absent(),
                Value<String> encMode = const Value.absent(),
                required bool incoming,
                Value<bool> delivered = const Value.absent(),
                Value<bool> isCarbon = const Value.absent(),
                Value<String> deliveryError = const Value.absent(),
                Value<bool> retracted = const Value.absent(),
                Value<DateTime> retractedAt = const Value.absent(),
                Value<String> replyTo = const Value.absent(),
                Value<String> replyBody = const Value.absent(),
                Value<String> replyAuthor = const Value.absent(),
                Value<DateTime?> editedAt = const Value.absent(),
              }) => MessagesCompanion.insert(
                id: id,
                chatJid: chatJid,
                sender: sender,
                stanzaId: stanzaId,
                body: body,
                timestamp: timestamp,
                encMode: encMode,
                incoming: incoming,
                delivered: delivered,
                isCarbon: isCarbon,
                deliveryError: deliveryError,
                retracted: retracted,
                retractedAt: retractedAt,
                replyTo: replyTo,
                replyBody: replyBody,
                replyAuthor: replyAuthor,
                editedAt: editedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessagesTable, Message>(table),
                  $$MessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({chatJid = false}) {
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
                    if (chatJid) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.chatJid,
                        referencedTable: $$MessagesTableReferences
                            ._chatJidTable(db),
                        referencedColumn: $$MessagesTableReferences
                            ._chatJidTable(db)
                            .jid,
                      ) as T;
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

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagesTable,
      Message,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (Message, $$MessagesTableReferences),
      Message,
      PrefetchHooks Function({bool chatJid})
    >;
typedef $$RosterEntriesTableCreateCompanionBuilder =
    RosterEntriesCompanion Function({
      required String jid,
      Value<String> name,
      Value<String> subscription,
      Value<String> ask,
      Value<String> groups,
      Value<int> rowid,
    });
typedef $$RosterEntriesTableUpdateCompanionBuilder =
    RosterEntriesCompanion Function({
      Value<String> jid,
      Value<String> name,
      Value<String> subscription,
      Value<String> ask,
      Value<String> groups,
      Value<int> rowid,
    });

class $$RosterEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $RosterEntriesTable> {
  $$RosterEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get jid => $composableBuilder(
    column: $table.jid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subscription => $composableBuilder(
    column: $table.subscription,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ask => $composableBuilder(
    column: $table.ask,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groups => $composableBuilder(
    column: $table.groups,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RosterEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $RosterEntriesTable> {
  $$RosterEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get jid => $composableBuilder(
    column: $table.jid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subscription => $composableBuilder(
    column: $table.subscription,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ask => $composableBuilder(
    column: $table.ask,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groups => $composableBuilder(
    column: $table.groups,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RosterEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RosterEntriesTable> {
  $$RosterEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get jid =>
      $composableBuilder(column: $table.jid, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get subscription => $composableBuilder(
    column: $table.subscription,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ask =>
      $composableBuilder(column: $table.ask, builder: (column) => column);

  GeneratedColumn<String> get groups =>
      $composableBuilder(column: $table.groups, builder: (column) => column);
}

class $$RosterEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RosterEntriesTable,
          RosterEntry,
          $$RosterEntriesTableFilterComposer,
          $$RosterEntriesTableOrderingComposer,
          $$RosterEntriesTableAnnotationComposer,
          $$RosterEntriesTableCreateCompanionBuilder,
          $$RosterEntriesTableUpdateCompanionBuilder,
          (
            RosterEntry,
            BaseReferences<_$AppDatabase, $RosterEntriesTable, RosterEntry>,
          ),
          RosterEntry,
          PrefetchHooks Function()
        > {
  $$RosterEntriesTableTableManager(_$AppDatabase db, $RosterEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RosterEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RosterEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RosterEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> jid = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> subscription = const Value.absent(),
                Value<String> ask = const Value.absent(),
                Value<String> groups = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RosterEntriesCompanion(
                jid: jid,
                name: name,
                subscription: subscription,
                ask: ask,
                groups: groups,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String jid,
                Value<String> name = const Value.absent(),
                Value<String> subscription = const Value.absent(),
                Value<String> ask = const Value.absent(),
                Value<String> groups = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RosterEntriesCompanion.insert(
                jid: jid,
                name: name,
                subscription: subscription,
                ask: ask,
                groups: groups,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RosterEntriesTable, RosterEntry>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $RosterEntriesTable,
                    RosterEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RosterEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RosterEntriesTable,
      RosterEntry,
      $$RosterEntriesTableFilterComposer,
      $$RosterEntriesTableOrderingComposer,
      $$RosterEntriesTableAnnotationComposer,
      $$RosterEntriesTableCreateCompanionBuilder,
      $$RosterEntriesTableUpdateCompanionBuilder,
      (
        RosterEntry,
        BaseReferences<_$AppDatabase, $RosterEntriesTable, RosterEntry>,
      ),
      RosterEntry,
      PrefetchHooks Function()
    >;
typedef $$PendingCorrectionsTableCreateCompanionBuilder =
    PendingCorrectionsCompanion Function({
      required String targetId,
      required String body,
      Value<String> encMode,
      Value<DateTime> correctedAt,
      Value<int> rowid,
    });
typedef $$PendingCorrectionsTableUpdateCompanionBuilder =
    PendingCorrectionsCompanion Function({
      Value<String> targetId,
      Value<String> body,
      Value<String> encMode,
      Value<DateTime> correctedAt,
      Value<int> rowid,
    });

class $$PendingCorrectionsTableFilterComposer
    extends Composer<_$AppDatabase, $PendingCorrectionsTable> {
  $$PendingCorrectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encMode => $composableBuilder(
    column: $table.encMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get correctedAt => $composableBuilder(
    column: $table.correctedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PendingCorrectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingCorrectionsTable> {
  $$PendingCorrectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encMode => $composableBuilder(
    column: $table.encMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get correctedAt => $composableBuilder(
    column: $table.correctedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PendingCorrectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingCorrectionsTable> {
  $$PendingCorrectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get targetId =>
      $composableBuilder(column: $table.targetId, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get encMode =>
      $composableBuilder(column: $table.encMode, builder: (column) => column);

  GeneratedColumn<DateTime> get correctedAt => $composableBuilder(
    column: $table.correctedAt,
    builder: (column) => column,
  );
}

class $$PendingCorrectionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PendingCorrectionsTable,
          PendingCorrection,
          $$PendingCorrectionsTableFilterComposer,
          $$PendingCorrectionsTableOrderingComposer,
          $$PendingCorrectionsTableAnnotationComposer,
          $$PendingCorrectionsTableCreateCompanionBuilder,
          $$PendingCorrectionsTableUpdateCompanionBuilder,
          (
            PendingCorrection,
            BaseReferences<
              _$AppDatabase,
              $PendingCorrectionsTable,
              PendingCorrection
            >,
          ),
          PendingCorrection,
          PrefetchHooks Function()
        > {
  $$PendingCorrectionsTableTableManager(
    _$AppDatabase db,
    $PendingCorrectionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingCorrectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingCorrectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingCorrectionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> targetId = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String> encMode = const Value.absent(),
                Value<DateTime> correctedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingCorrectionsCompanion(
                targetId: targetId,
                body: body,
                encMode: encMode,
                correctedAt: correctedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String targetId,
                required String body,
                Value<String> encMode = const Value.absent(),
                Value<DateTime> correctedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingCorrectionsCompanion.insert(
                targetId: targetId,
                body: body,
                encMode: encMode,
                correctedAt: correctedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PendingCorrectionsTable, PendingCorrection>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $PendingCorrectionsTable,
                    PendingCorrection
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PendingCorrectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PendingCorrectionsTable,
      PendingCorrection,
      $$PendingCorrectionsTableFilterComposer,
      $$PendingCorrectionsTableOrderingComposer,
      $$PendingCorrectionsTableAnnotationComposer,
      $$PendingCorrectionsTableCreateCompanionBuilder,
      $$PendingCorrectionsTableUpdateCompanionBuilder,
      (
        PendingCorrection,
        BaseReferences<
          _$AppDatabase,
          $PendingCorrectionsTable,
          PendingCorrection
        >,
      ),
      PendingCorrection,
      PrefetchHooks Function()
    >;
typedef $$ReactionsTableCreateCompanionBuilder = ReactionsCompanion Function({
  required String targetId,
  required String emoji,
  required String reactor,
  Value<DateTime> reactedAt,
  Value<int> rowid,
});
typedef $$ReactionsTableUpdateCompanionBuilder = ReactionsCompanion Function({
  Value<String> targetId,
  Value<String> emoji,
  Value<String> reactor,
  Value<DateTime> reactedAt,
  Value<int> rowid,
});

class $$ReactionsTableFilterComposer
    extends Composer<_$AppDatabase, $ReactionsTable> {
  $$ReactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get emoji => $composableBuilder(
    column: $table.emoji,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reactor => $composableBuilder(
    column: $table.reactor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get reactedAt => $composableBuilder(
    column: $table.reactedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReactionsTableOrderingComposer
    extends Composer<_$AppDatabase, $ReactionsTable> {
  $$ReactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get emoji => $composableBuilder(
    column: $table.emoji,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reactor => $composableBuilder(
    column: $table.reactor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get reactedAt => $composableBuilder(
    column: $table.reactedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReactionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReactionsTable> {
  $$ReactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get targetId =>
      $composableBuilder(column: $table.targetId, builder: (column) => column);

  GeneratedColumn<String> get emoji =>
      $composableBuilder(column: $table.emoji, builder: (column) => column);

  GeneratedColumn<String> get reactor =>
      $composableBuilder(column: $table.reactor, builder: (column) => column);

  GeneratedColumn<DateTime> get reactedAt =>
      $composableBuilder(column: $table.reactedAt, builder: (column) => column);
}

class $$ReactionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReactionsTable,
          Reaction,
          $$ReactionsTableFilterComposer,
          $$ReactionsTableOrderingComposer,
          $$ReactionsTableAnnotationComposer,
          $$ReactionsTableCreateCompanionBuilder,
          $$ReactionsTableUpdateCompanionBuilder,
          (Reaction, BaseReferences<_$AppDatabase, $ReactionsTable, Reaction>),
          Reaction,
          PrefetchHooks Function()
        > {
  $$ReactionsTableTableManager(_$AppDatabase db, $ReactionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReactionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReactionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> targetId = const Value.absent(),
                Value<String> emoji = const Value.absent(),
                Value<String> reactor = const Value.absent(),
                Value<DateTime> reactedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReactionsCompanion(
                targetId: targetId,
                emoji: emoji,
                reactor: reactor,
                reactedAt: reactedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String targetId,
                required String emoji,
                required String reactor,
                Value<DateTime> reactedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReactionsCompanion.insert(
                targetId: targetId,
                emoji: emoji,
                reactor: reactor,
                reactedAt: reactedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReactionsTable, Reaction>(table),
                  BaseReferences<_$AppDatabase, $ReactionsTable, Reaction>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReactionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReactionsTable,
      Reaction,
      $$ReactionsTableFilterComposer,
      $$ReactionsTableOrderingComposer,
      $$ReactionsTableAnnotationComposer,
      $$ReactionsTableCreateCompanionBuilder,
      $$ReactionsTableUpdateCompanionBuilder,
      (Reaction, BaseReferences<_$AppDatabase, $ReactionsTable, Reaction>),
      Reaction,
      PrefetchHooks Function()
    >;
typedef $$MetaTableCreateCompanionBuilder = MetaCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$MetaTableUpdateCompanionBuilder = MetaCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$MetaTableFilterComposer extends Composer<_$AppDatabase, $MetaTable> {
  $$MetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MetaTableOrderingComposer extends Composer<_$AppDatabase, $MetaTable> {
  $$MetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $MetaTable> {
  $$MetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$MetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MetaTable,
          MetaData,
          $$MetaTableFilterComposer,
          $$MetaTableOrderingComposer,
          $$MetaTableAnnotationComposer,
          $$MetaTableCreateCompanionBuilder,
          $$MetaTableUpdateCompanionBuilder,
          (MetaData, BaseReferences<_$AppDatabase, $MetaTable, MetaData>),
          MetaData,
          PrefetchHooks Function()
        > {
  $$MetaTableTableManager(_$AppDatabase db, $MetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MetaTable, MetaData>(table),
                  BaseReferences<_$AppDatabase, $MetaTable, MetaData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MetaTable,
      MetaData,
      $$MetaTableFilterComposer,
      $$MetaTableOrderingComposer,
      $$MetaTableAnnotationComposer,
      $$MetaTableCreateCompanionBuilder,
      $$MetaTableUpdateCompanionBuilder,
      (MetaData, BaseReferences<_$AppDatabase, $MetaTable, MetaData>),
      MetaData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ChatsTableTableManager get chats =>
      $$ChatsTableTableManager(_db, _db.chats);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$RosterEntriesTableTableManager get rosterEntries =>
      $$RosterEntriesTableTableManager(_db, _db.rosterEntries);
  $$PendingCorrectionsTableTableManager get pendingCorrections =>
      $$PendingCorrectionsTableTableManager(_db, _db.pendingCorrections);
  $$ReactionsTableTableManager get reactions =>
      $$ReactionsTableTableManager(_db, _db.reactions);
  $$MetaTableTableManager get meta => $$MetaTableTableManager(_db, _db.meta);
}
