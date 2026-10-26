// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Conversations MultiUserChatManager.createPrivateGroupChat /
// createPublicChannel defaults and pronounceable room localparts.

import 'dart:math';

/// Conversations `CryptoHelper.pronounceable` — random localpart for private
/// group JIDs (`name@conference.example`).
String pronounceableRoomLocalpart([Random? random]) {
  final rng = random ?? Random.secure();
  const vowels = 'aeiou';
  const consonants = 'bcdfghjklmnpqrstvwxyz';
  final rand = rng.nextInt(4);
  final length = rand * 2 + (5 - rand);
  var vowel = rng.nextBool();
  final out = StringBuffer();
  for (var i = 0; i < length; i++) {
    out.write(
      vowel
          ? vowels[rng.nextInt(vowels.length)]
          : consonants[rng.nextInt(consonants.length)],
    );
    vowel = !vowel;
  }
  return out.toString();
}

/// Conversations `defaultGroupChatConfiguration` (+ optional room name).
Map<String, Object> defaultGroupChatConfiguration({String? name}) {
  final map = <String, Object>{
    'muc#roomconfig_persistentroom': true,
    'muc#roomconfig_membersonly': true,
    'muc#roomconfig_publicroom': false,
    'muc#roomconfig_whois': 'anyone',
    'muc#roomconfig_changesubject': false,
    'muc#roomconfig_allowinvites': false,
    'muc#roomconfig_enablearchiving': true,
    'mam': true,
    'muc#roomconfig_mam': true,
    'muc#roomconfig_enablelogging': false,
  };
  final n = name?.trim();
  if (n != null && n.isNotEmpty) {
    map['muc#roomconfig_roomname'] = n;
  }
  return map;
}

/// Conversations `defaultChannelConfiguration` (+ optional room name).
Map<String, Object> defaultChannelConfiguration({String? name}) {
  final map = <String, Object>{
    'muc#roomconfig_persistentroom': true,
    'muc#roomconfig_membersonly': false,
    'muc#roomconfig_publicroom': true,
    'muc#roomconfig_whois': 'moderators',
    'muc#roomconfig_changesubject': false,
    'muc#roomconfig_enablearchiving': true,
    'mam': true,
    'muc#roomconfig_mam': true,
  };
  final n = name?.trim();
  if (n != null && n.isNotEmpty) {
    map['muc#roomconfig_roomname'] = n;
  }
  return map;
}

/// Form field value as Conversations `Data.submit` expects it.
String roomConfigFormValue(Object value) {
  if (value is bool) return value ? '1' : '0';
  return '$value';
}

/// Outcome of [XmppService.createPrivateGroupChat] /
/// [XmppService.createPublicChannel].
class CreateRoomResult {
  const CreateRoomResult.ok({
    required this.roomJid,
    required this.nick,
    required this.title,
    required this.privateNonAnonymous,
  }) : error = null;

  const CreateRoomResult.fail(this.error)
    : roomJid = null,
      nick = null,
      title = null,
      privateNonAnonymous = false;

  final String? roomJid;
  final String? nick;
  final String? title;
  final bool privateNonAnonymous;
  final String? error;

  bool get ok => roomJid != null && error == null;
}
