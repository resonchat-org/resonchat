// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Platform-swapped Drift executor (matrix-dart-sdk style conditional import):
//   native → SQLCipher / SQLite file
//   web    → sqlite3.wasm + OPFS / IndexedDB

export 'package:resonchat/persistence/database_connection_io.dart'
    if (dart.library.js_interop) 'package:resonchat/persistence/database_connection_web.dart';
