// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Point relative lib imports at package:resonchat, then sort with
// package:import_sorter: dart:, package:flutter/, other packages, this
// package. Conditional `if (dart.library…)` imports are masked first —
// import_sorter treats any line containing `dart:` as a dart import.
// `part` / `part of` stay relative; Dart requires that.
//
// Run from app/ (scripts/format.sh does):
//   dart --packages=.dart_tool/package_config.json ../scripts/sort_imports.dart

import 'dart:io';

import 'package:import_sorter/sort.dart';

const _libraryToken = '__LIB__';

void main() {
  if (!File('pubspec.yaml').existsSync()) {
    stderr.writeln('Run this from app/ (./scripts/format.sh does that).');
    exit(64);
  }
  final packageName = _packageName(File('pubspec.yaml').readAsStringSync());
  final libRoot = Directory('lib').absolute.uri.toFilePath();
  var changed = 0;
  var scanned = 0;
  for (final root in ['lib', 'test', 'integration_test', 'tool']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final next = _process(
        entity.readAsStringSync(),
        filePath: entity.absolute.path,
        packageName: packageName,
        libRoot: libRoot,
      );
      if (next == null) continue;
      entity.writeAsStringSync(next);
      changed++;
    }
  }
  stdout.writeln('Sorted imports in $changed of $scanned Dart files.');
}

String _packageName(String pubspec) {
  final match = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec);
  if (match == null) {
    stderr.writeln('pubspec.yaml has no package name.');
    exit(64);
  }
  return match.group(1)!;
}

/// Returns the rewritten file, or null when nothing changed.
String? _process(
  String source, {
  required String filePath,
  required String packageName,
  required String libRoot,
}) {
  final lines = source.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  final prefix = <String>[];
  var i = 0;
  while (i < lines.length && !_isDirective(lines[i])) {
    prefix.add(lines[i]);
    i++;
  }

  final imports = <_Directive>[];
  final exports = <_Directive>[];
  final parts = <_Directive>[];
  while (i < lines.length) {
    final trimmed = lines[i].trim();
    if (trimmed.isEmpty) {
      i++;
      continue;
    }
    if (trimmed.startsWith('//') || trimmed.startsWith('/*')) break;
    if (!_isDirective(lines[i])) break;
    final raw = <String>[lines[i]];
    while (!raw.last.contains(';') && i + 1 < lines.length) {
      i++;
      raw.add(lines[i]);
    }
    final kind = _kind(raw.first.trimLeft());
    final joined = raw.map((line) => line.trim()).join(' ');
    final text = _rewriteUris(
      joined,
      kind: kind,
      filePath: filePath,
      packageName: packageName,
      libRoot: libRoot,
    );
    final directive = _Directive(kind, text, raw.join('\n'));
    switch (kind) {
      case 'import':
        imports.add(directive);
      case 'export':
        exports.add(directive);
      default:
        parts.add(directive);
    }
    i++;
  }
  if (imports.isEmpty && exports.isEmpty && parts.isEmpty) return null;

  final suffix = lines.sublist(i);
  while (suffix.isNotEmpty && suffix.first.trim().isEmpty) {
    suffix.removeAt(0);
  }

  final out = <String>[...prefix];
  if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
  final blocks = <String>[
    if (imports.isNotEmpty) _emitSorted(imports, packageName),
    if (exports.isNotEmpty) _emitSorted(exports, packageName),
    if (parts.isNotEmpty) parts.map((part) => part.emitted).join('\n'),
  ];
  for (var b = 0; b < blocks.length; b++) {
    if (b > 0) out.add('');
    out.addAll(blocks[b].split('\n'));
  }
  if (suffix.isNotEmpty) {
    if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
    out.addAll(suffix);
  }
  final next = '${out.join('\n')}\n';
  return next == source ? null : next;
}

bool _isDirective(String line) {
  final s = line.trimLeft();
  return s.startsWith('import ') ||
      s.startsWith('export ') ||
      s.startsWith('part ');
}

class _Directive {
  _Directive(this.kind, this.normalized, this.original);

  final String kind;
  final String normalized;
  final String original;

  /// Keep dart format's wrapping when the URI did not change.
  String get emitted {
    final joined = original
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
    return joined == normalized ? original : normalized;
  }
}

String _kind(String text) {
  if (text.startsWith('import ')) return 'import';
  if (text.startsWith('export ')) return 'export';
  return 'part';
}

String _rewriteUris(
  String directive, {
  required String kind,
  required String filePath,
  required String packageName,
  required String libRoot,
}) {
  if (kind == 'part') return directive;
  return directive.replaceAllMapped(RegExp('\'([^\']*)\'|"([^"]*)"'), (m) {
    final quoted = m.group(0)!;
    final uri = m.group(1) ?? m.group(2)!;
    if (uri.startsWith('package:') || uri.startsWith('dart:')) return quoted;
    final resolved = File(filePath).absolute.uri.resolve(uri).toFilePath();
    final root = libRoot.endsWith(Platform.pathSeparator)
        ? libRoot
        : '$libRoot${Platform.pathSeparator}';
    if (resolved != libRoot && !resolved.startsWith(root)) return quoted;
    final rel = resolved
        .substring(root.length)
        .replaceAll(Platform.pathSeparator, '/');
    final quote = quoted[0];
    return '${quote}package:$packageName/$rel$quote';
  });
}

String _sortImports(List<String> lines, String packageName) {
  final masked = lines
      .map((line) => line.replaceAll('dart.library', _libraryToken))
      .toList();
  return sortImports(
    masked,
    packageName,
    false,
    false,
    true,
  ).sortedFile.replaceAll(_libraryToken, 'dart.library').trim();
}

String _emitSorted(List<_Directive> items, String packageName) {
  final exports = items.first.kind == 'export';
  final keys = items.map((item) => item.normalized).toList();
  final sorted = exports
      ? _sortExports(keys, packageName)
      : _sortImports(keys, packageName);
  final pending = <String, List<_Directive>>{};
  for (final item in items) {
    pending.putIfAbsent(item.normalized, () => []).add(item);
  }
  final out = <String>[];
  for (final line in sorted.split('\n')) {
    if (line.trim().isEmpty) {
      out.add('');
      continue;
    }
    final queue = pending[line];
    if (queue == null || queue.isEmpty) {
      out.add(line);
      continue;
    }
    out.add(queue.removeAt(0).emitted);
  }
  return out.join('\n');
}

String _sortExports(List<String> lines, String packageName) {
  final asImports = lines.map((line) => 'import ${line.substring(7)}').toList();
  return _sortImports(asImports, packageName)
      .split('\n')
      .map((line) {
        if (!line.startsWith('import ')) return line;
        return 'export ${line.substring('import '.length)}';
      })
      .join('\n');
}
