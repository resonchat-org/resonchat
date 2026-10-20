// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Public channel discovery (Conversations ChannelDiscoveryService):
// - LOCAL_SERVER: XEP-0030 disco#items on MUC hosts + disco#info per room
// - JABBER_NETWORK: HTTP Muclumbus API at search.jabber.network

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/net/app_network.dart';
import 'package:resonchat/persistence/prefs_database.dart';
import 'package:resonchat/xmpp/connection.dart';

const prefChannelDiscoveryMethodKey = 'pref_channel_discovery_method';
const prefChannelDiscoveryOptInKey = 'pref_channel_discovery_opt_in';

/// Conversations `Config.CHANNEL_DISCOVERY`.
const muclumbusBaseUrl = 'https://search.jabber.network';

enum ChannelDiscoveryMethod {
  jabberNetwork,
  localServer;

  String get stored => switch (this) {
    ChannelDiscoveryMethod.jabberNetwork => 'jabber_network',
    ChannelDiscoveryMethod.localServer => 'local_server',
  };

  static ChannelDiscoveryMethod parse(String? raw) {
    switch (raw) {
      case 'local_server':
        return ChannelDiscoveryMethod.localServer;
      case 'jabber_network':
      default:
        return ChannelDiscoveryMethod.jabberNetwork;
    }
  }
}

/// One public room from disco or Muclumbus (Conversations `Room`).
class PublicChannel {
  const PublicChannel({
    required this.address,
    required this.name,
    required this.description,
    this.language,
    this.numberOfUsers = 0,
  });

  final String address;
  final String name;
  final String description;
  final String? language;
  final int numberOfUsers;

  String get displayName => name.trim().isEmpty
      ? (address.contains('@') ? address.split('@').first : address)
      : name;

  bool matches(String needle) {
    if (needle.isEmpty) return true;
    final n = needle.toLowerCase();
    return name.toLowerCase().contains(n) ||
        description.toLowerCase().contains(n) ||
        address.toLowerCase().contains(n);
  }

  /// Conversations `Room.of` from disco#info + muc#roominfo.
  static PublicChannel? fromDiscoInfo(JID jid, DiscoInfo info) {
    Identity? identity;
    for (final i in info.identities) {
      if (i.category == 'conference') {
        identity = i;
        break;
      }
    }
    identity ??= info.identities.isEmpty ? null : info.identities.first;

    DataForm? roomInfo;
    for (final form in info.extendedInfo) {
      final ft = form.getFieldByVar(formVarFormType);
      if (ft?.type == 'hidden' &&
          ft!.values.isNotEmpty &&
          ft.values.first == roomInfoFormType) {
        roomInfo = form;
        break;
      }
    }

    String? field(String varName) {
      final values = roomInfo?.getFieldByVar(varName)?.values;
      if (values == null || values.isEmpty) return null;
      final v = values.first.trim();
      return v.isEmpty ? null : v;
    }

    final roomName = field('muc#roomconfig_roomname');
    final description = field('muc#roominfo_description') ?? '';
    final language = field('muc#roominfo_lang');
    final occupants = int.tryParse(field('muc#roominfo_occupants') ?? '') ?? 0;
    final name = (roomName != null && roomName.isNotEmpty)
        ? roomName
        : (identity?.name ?? '');

    return PublicChannel(
      address: jid.toBare().toString(),
      name: name,
      description: description,
      language: language,
      numberOfUsers: occupants,
    );
  }

  static PublicChannel? fromMuclumbusJson(Map<String, dynamic> json) {
    final address = json['address']?.toString() ?? '';
    if (address.isEmpty) return null;
    return PublicChannel(
      address: address,
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      language: json['language']?.toString(),
      numberOfUsers: (json['nusers'] as num?)?.toInt() ?? 0,
    );
  }
}

Future<ChannelDiscoveryMethod> loadChannelDiscoveryMethod([
  PrefsDatabase? prefs,
]) async {
  final db = prefs ?? appPrefs;
  return ChannelDiscoveryMethod.parse(
    await db.getString(prefChannelDiscoveryMethodKey),
  );
}

Future<void> saveChannelDiscoveryMethod(
  ChannelDiscoveryMethod method, [
  PrefsDatabase? prefs,
]) async {
  final db = prefs ?? appPrefs;
  await db.setString(prefChannelDiscoveryMethodKey, method.stored);
}

Future<bool> loadChannelDiscoveryOptIn([PrefsDatabase? prefs]) async {
  final db = prefs ?? appPrefs;
  return (await db.getString(prefChannelDiscoveryOptInKey)) == '1';
}

Future<void> saveChannelDiscoveryOptIn(
  bool optedIn, [
  PrefsDatabase? prefs,
]) async {
  final db = prefs ?? appPrefs;
  await db.setString(prefChannelDiscoveryOptInKey, optedIn ? '1' : '0');
}

/// Discovers public channels like Conversations `ChannelDiscoveryService`.
class ChannelDiscoveryService {
  ChannelDiscoveryService({
    required this.xmpp,
    http.Client Function()? clientFactory,
    this.muclumbusBase = muclumbusBaseUrl,
  }) : _clientFactory = clientFactory ?? appNetwork.createHttpClient;

  final XmppService xmpp;
  final http.Client Function() _clientFactory;
  final String muclumbusBase;
  final _log = Logger('ChannelDiscovery');

  final Map<String, List<PublicChannel>> _cache = {};

  static String _cacheKey(ChannelDiscoveryMethod method, String query) =>
      '${method.stored}\u0000$query';

  Future<List<PublicChannel>> discover(
    String query, {
    required ChannelDiscoveryMethod method,
  }) async {
    final q = query.trim();
    final cached = _cache[_cacheKey(method, q)];
    if (cached != null) return List<PublicChannel>.from(cached);

    final results = method == ChannelDiscoveryMethod.localServer
        ? await _discoverLocal(q)
        : await _discoverMuclumbus(q);

    _cache[_cacheKey(method, q)] = results;
    return results;
  }

  void clearCache() => _cache.clear();

  Future<List<PublicChannel>> _discoverMuclumbus(String query) async {
    final client = _clientFactory();
    try {
      if (query.isEmpty) {
        final uri = Uri.parse('$muclumbusBase/api/1.0/rooms/unsafe?p=1');
        final resp = await client.get(uri);
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          _log.warning('muclumbus rooms HTTP ${resp.statusCode}');
          return const [];
        }
        final body = jsonDecode(resp.body);
        if (body is! Map) return const [];
        final items = body['items'];
        if (items is! List) return const [];
        return _sorted(
          items
              .whereType<Map>()
              .map(
                (e) => PublicChannel.fromMuclumbusJson(
                  Map<String, dynamic>.from(e),
                ),
              )
              .whereType<PublicChannel>(),
        );
      }

      final uri = Uri.parse('$muclumbusBase/api/1.0/search');
      final resp = await client.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'keywords': [query],
        }),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _log.warning('muclumbus search HTTP ${resp.statusCode}');
        return const [];
      }
      final body = jsonDecode(resp.body);
      if (body is! Map) return const [];
      final result = body['result'];
      if (result is! Map) return const [];
      final items = result['items'];
      if (items is! List) return const [];
      return _sorted(
        items
            .whereType<Map>()
            .map(
              (e) =>
                  PublicChannel.fromMuclumbusJson(Map<String, dynamic>.from(e)),
            )
            .whereType<PublicChannel>(),
      );
    } catch (e, st) {
      _log.warning('muclumbus failed: $e', e, st);
      return const [];
    } finally {
      client.close();
    }
  }

  Future<List<PublicChannel>> _discoverLocal(String query) async {
    final dm = xmpp.disco;
    if (dm == null) return const [];

    var services = dm.mucServices;
    if (services.isEmpty) {
      final sweep = await dm.performDiscoSweep();
      if (sweep.isType<DiscoError>()) {
        _log.warning('disco sweep failed for channel discovery');
      }
      services = dm.mucServices;
    }
    if (services.isEmpty) return const [];

    final rooms = <PublicChannel>[];
    for (final service in services) {
      rooms.addAll(await _discoverRoomsOn(dm, service));
    }
    final sorted = _sorted(rooms);
    _cache[_cacheKey(ChannelDiscoveryMethod.localServer, '')] = sorted;
    if (query.isEmpty) return sorted;
    return sorted.where((r) => r.matches(query)).toList();
  }

  Future<List<PublicChannel>> _discoverRoomsOn(
    DiscoManager dm,
    JID service,
  ) async {
    final itemsResult = await dm.discoItemsQuery(service);
    if (!itemsResult.isType<List<DiscoItem>>()) return const [];
    final items = itemsResult.get<List<DiscoItem>>();
    final rooms = <PublicChannel>[];
    // Bound concurrency: a busy MUC host can list hundreds of rooms.
    const batch = 8;
    for (var i = 0; i < items.length; i += batch) {
      final slice = items.skip(i).take(batch);
      final chunk = await Future.wait(
        slice.map((item) => _discoverRoom(dm, item.jid)),
      );
      for (final room in chunk) {
        if (room != null) rooms.add(room);
      }
    }
    return rooms;
  }

  Future<PublicChannel?> _discoverRoom(DiscoManager dm, JID roomJid) async {
    final infoResult = await dm.discoInfoQuery(roomJid, shouldCache: false);
    if (!infoResult.isType<DiscoInfo>()) return null;
    return PublicChannel.fromDiscoInfo(roomJid, infoResult.get<DiscoInfo>());
  }

  List<PublicChannel> _sorted(Iterable<PublicChannel> rooms) {
    final list = rooms.toList();
    list.sort((a, b) {
      final byUsers = b.numberOfUsers.compareTo(a.numberOfUsers);
      if (byUsers != 0) return byUsers;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      return a.address.toLowerCase().compareTo(b.address.toLowerCase());
    });
    return list;
  }
}
