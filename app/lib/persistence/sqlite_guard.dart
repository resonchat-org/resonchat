// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';

import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

/// The Dart-implemented SQL functions Drift installs on *every* database it
/// opens.
///
/// Mirrors `useNativeFunctions` in
/// `drift/lib/src/sqlite3/native_functions.dart`; that call is unconditional
/// and cannot be turned off. See [guardedSqlite3] for why we drop it.
const Set<String> kDriftBuiltinFunctions = {
  'power',
  'pow',
  'sqrt',
  'sin',
  'cos',
  'tan',
  'asin',
  'acos',
  'atan',
  'regexp',
  'regexp_moor_ffi',
  'moor_contains',
  'current_time_millis',
};

/// A `SqliteResolver` for [NativeDatabase] that opens sqlite3 with Drift's
/// built-in Dart SQL functions removed.
///
/// ## Why this exists
///
/// Handing sqlite3 a single Dart closure makes `dart:ffi` build a native call
/// trampoline: an anonymous page is flipped to `PROT_EXEC` with `mprotect`.
/// Android's SELinux policy denies `execmem` to `untrusted_app`, so on Android
/// 16+ that `mprotect` returns `EACCES`, and the Dart VM aborts the **whole
/// process** on the thread that tried it:
///
/// ```
/// Abort message: '../../../flutter/third_party/dart/runtime/vm/virtual_memory_posix.cc: 801:
///                 error: mprotect failed: 13 (Permission denied)'
/// ```
///
/// Drift triggers exactly this path when it opens a database: `Sqlite3Delegate`
/// calls `database.useNativeFunctions()` on every open, registering the
/// [kDriftBuiltinFunctions] above. Because we open our databases with
/// `NativeDatabase.createInBackground`, the crash lands on the background
/// isolate's `DartWorker` thread, seconds into startup.
///
/// Upstream references: flutter/flutter#191385, dart-lang/sdk#64137. Drift has
/// no opt-out flag (checked through 2.35.2).
///
/// ## What it does
///
/// ResonChat uses none of those functions, so we open sqlite3 through a thin
/// wrapper whose `createFunction` ignores exactly [kDriftBuiltinFunctions].
/// **Everything else is forwarded untouched**, so the guard is identical to
/// stock Drift except for those removals — any other function we ever register
/// still behaves (and still crashes the same way stock Drift would) rather than
/// being silently dropped.
///
/// On platforms without the `execmem` restriction this changes nothing we
/// depend on. It is deliberately *not* gated to Android so that the CI suite
/// exercises the same code path everywhere.
Sqlite3 guardedSqlite3() => _GuardedSqlite3(sqlite3);

/// Unwraps a [Database] so a guarded one can be handed back to native code
/// expecting the real connection.
Database _unwrap(Database database) =>
    database is _GuardedDatabase ? database._inner : database;

final class _GuardedSqlite3 implements Sqlite3 {
  _GuardedSqlite3(this._inner);

  final Sqlite3 _inner;

  @override
  Version get version => _inner.version;

  @override
  Database open(
    String filename, {
    String? vfs,
    OpenMode mode = OpenMode.readWriteCreate,
    bool uri = false,
    bool? mutex,
  }) {
    return _GuardedDatabase(
      _inner.open(filename, vfs: vfs, mode: mode, uri: uri, mutex: mutex),
    );
  }

  @override
  Database fromPointer(Pointer<void> database, {bool borrowed = false}) {
    return _GuardedDatabase(_inner.fromPointer(database, borrowed: borrowed));
  }

  @override
  Database openInMemory({String? vfs}) {
    return _GuardedDatabase(_inner.openInMemory(vfs: vfs));
  }

  @override
  Database copyIntoMemory(Database restoreFrom) {
    return _GuardedDatabase(_inner.copyIntoMemory(_unwrap(restoreFrom)));
  }

  @override
  void ensureExtensionLoaded(SqliteExtension extension) {
    _inner.ensureExtensionLoaded(extension);
  }

  @override
  bool usedCompileOption(String name) => _inner.usedCompileOption(name);

  @override
  Iterable<String> get compileOptions => _inner.compileOptions;

  @override
  String? get tempDirectory => _inner.tempDirectory;

  @override
  set tempDirectory(String? value) => _inner.tempDirectory = value;

  @override
  void registerVirtualFileSystem(
    VirtualFileSystem vfs, {
    bool makeDefault = false,
  }) {
    _inner.registerVirtualFileSystem(vfs, makeDefault: makeDefault);
  }

  @override
  void unregisterVirtualFileSystem(VirtualFileSystem vfs) {
    _inner.unregisterVirtualFileSystem(vfs);
  }
}

final class _GuardedDatabase implements Database {
  _GuardedDatabase(this._inner);

  final Database _inner;

  // --- the only behaviour we change -----------------------------------------

  /// Drops Drift's own registrations and forwards anything else.
  ///
  /// This is the single reason the wrapper exists; see [guardedSqlite3].
  @override
  void createFunction({
    required String functionName,
    required ScalarFunction function,
    AllowedArgumentCount argumentCount = const AllowedArgumentCount.any(),
    bool deterministic = false,
    bool directOnly = true,
    bool subtype = false,
  }) {
    if (kDriftBuiltinFunctions.contains(functionName)) return;
    _inner.createFunction(
      functionName: functionName,
      function: function,
      argumentCount: argumentCount,
      deterministic: deterministic,
      directOnly: directOnly,
      subtype: subtype,
    );
  }

  // --- everything below is plain delegation ---------------------------------

  @override
  DatabaseConfig get config => _inner.config;

  @override
  int get userVersion => _inner.userVersion;

  @override
  set userVersion(int value) => _inner.userVersion = value;

  @override
  int get lastInsertRowId => _inner.lastInsertRowId;

  @override
  int get updatedRows => _inner.updatedRows;

  @override
  @Deprecated('Use updatedRows instead')
  int getUpdatedRows() => _inner.getUpdatedRows();

  @override
  Stream<SqliteUpdate> get updates => _inner.updates;

  @override
  Stream<SqliteUpdate> get updatesSync => _inner.updatesSync;

  @override
  VoidPredicate? get commitFilter => _inner.commitFilter;

  @override
  set commitFilter(VoidPredicate? commitFilter) =>
      _inner.commitFilter = commitFilter;

  @override
  Stream<void> get commits => _inner.commits;

  @override
  Stream<void> get rollbacks => _inner.rollbacks;

  @override
  void execute(String sql, [List<Object?> parameters = const []]) =>
      _inner.execute(sql, parameters);

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      _inner.select(sql, parameters);

  @override
  PreparedStatement prepare(
    String sql, {
    bool persistent = false,
    bool vtab = true,
    bool checkNoTail = false,
  }) {
    return _inner.prepare(
      sql,
      persistent: persistent,
      vtab: vtab,
      checkNoTail: checkNoTail,
    );
  }

  @override
  List<PreparedStatement> prepareMultiple(
    String sql, {
    bool persistent = false,
    bool vtab = true,
  }) {
    return _inner.prepareMultiple(sql, persistent: persistent, vtab: vtab);
  }

  @override
  PreparedStatement statementFromPointer({
    required Pointer<void> statement,
    required String sql,
    bool borrowed = false,
  }) {
    return _inner.statementFromPointer(
      statement: statement,
      sql: sql,
      borrowed: borrowed,
    );
  }

  @override
  Stream<double> backup(Database toDatabase, {int nPage = 5}) =>
      _inner.backup(_unwrap(toDatabase), nPage: nPage);

  @override
  void createCollation({
    required String name,
    required CollatingFunction function,
  }) {
    _inner.createCollation(name: name, function: function);
  }

  @override
  void createAggregateFunction<V>({
    required String functionName,
    required AggregateFunction<V> function,
    AllowedArgumentCount argumentCount = const AllowedArgumentCount.any(),
    bool deterministic = false,
    bool directOnly = true,
    bool subtype = false,
  }) {
    _inner.createAggregateFunction<V>(
      functionName: functionName,
      function: function,
      argumentCount: argumentCount,
      deterministic: deterministic,
      directOnly: directOnly,
      subtype: subtype,
    );
  }

  @override
  set busyHandler(bool Function(int count)? handler) =>
      _inner.busyHandler = handler;

  @override
  bool get autocommit => _inner.autocommit;

  @override
  @Deprecated('Call close() instead')
  void dispose() => _inner.dispose();

  @override
  void close() => _inner.close();

  @override
  Pointer<void> get handle => _inner.handle;

  @override
  Pointer<void> leak() => _inner.leak();
}
