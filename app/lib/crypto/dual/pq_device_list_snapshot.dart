// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One peer's OMEMO2 / PQ device-list snapshot. The cache and its refresh
// policy live in CapabilityService (docs/11 §4); this type only carries the
// answer plus enough metadata to decide whether it may be reused.

class PqDeviceListSnapshot {
  const PqDeviceListSnapshot({
    required this.devices,
    required this.fetchedAt,
    required this.expiresAt,
    required this.reliable,
    required this.generation,
  });

  /// Device ids advertised on the B-track PEP node.
  final Set<int> devices;

  final DateTime fetchedAt;
  final DateTime expiresAt;

  /// False means the list could not be read. Never treated as "no devices".
  final bool reliable;

  /// Per-peer generation captured when the lookup started. A result whose
  /// generation is stale must not be installed into the cache.
  final int generation;

  bool get isFresh => reliable && DateTime.now().isBefore(expiresAt);

  PqDeviceListSnapshot copyWith({
    Set<int>? devices,
    DateTime? fetchedAt,
    DateTime? expiresAt,
    bool? reliable,
    int? generation,
  }) {
    return PqDeviceListSnapshot(
      devices: devices ?? this.devices,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      reliable: reliable ?? this.reliable,
      generation: generation ?? this.generation,
    );
  }
}
