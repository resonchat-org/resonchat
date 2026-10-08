// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform-swapped Drift executor (matrix-dart-sdk style conditional import):
//   native → SQLCipher / SQLite file
//   web    → sqlite3.wasm + OPFS / IndexedDB

export 'database_connection_io.dart'
    if (dart.library.js_interop) 'database_connection_web.dart';
