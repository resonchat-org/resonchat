// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copinc `RoomConfigTranslator`: Prosody (and similar) return English form
// labels; map them to app l10n. Servers that honor `xml:lang` (ejabberd) may
// already send localized text — unknown strings pass through unchanged.
//
// Switch arms match Prosody's English strings literally (they say "room").

import '../l10n/generated/app_localizations.dart';

/// Translates room-config form title / labels / option labels when the server
/// did not localize them.
String translateRoomConfigLabel(AppLocalizations l10n, String? label) {
  if (label == null || label.isEmpty) return '';

  if (label.startsWith('Configuration for ')) {
    return l10n.roomConfTitle(label.substring('Configuration for '.length));
  }

  switch (label) {
    case 'Complete and submit this form to configure the room.':
      return l10n.roomConfInstructions;
    case 'Room information':
      return l10n.roomConfInfo;
    case 'Access to the room':
      return l10n.roomConfAccess;
    case 'Permissions in the room':
      return l10n.roomConfPermissions;
    case 'Other options':
      return l10n.roomConfOtherOptions;
    case 'Allow members to invite new members':
      return l10n.roomConfAllowMemberInvites;
    case 'Allow anyone to set the room\'s subject':
      return l10n.roomConfChangeSubject;
    case 'Choose whether anyone, or only moderators, may set the room\'s subject':
      return l10n.roomConfChangeSubjectDesc;
    case 'Language tag for room (e.g. \'en\', \'de\', \'fr\' etc.)':
      return l10n.roomConfLang;
    case 'Indicate the primary language spoken in this room':
      return l10n.roomConfLangDesc;
    case 'Only allow members to join':
      return l10n.roomConfMembersOnly;
    case 'Enable this to only allow access for room owners, admins and members':
      return l10n.roomConfMembersOnlyDesc;
    case 'Moderated (require permission to speak)':
      return l10n.roomConfModerated;
    case 'In moderated rooms occupants must be given permission to speak by a room moderator':
      return l10n.roomConfModeratedDesc;
    case 'Persistent (room should remain even when it is empty)':
      return l10n.roomConfPersistent;
    case 'Rooms are automatically deleted when they are empty, unless this option is enabled':
      return l10n.roomConfPersistentDesc;
    case 'Only show participants with roles:':
      return l10n.roomConfPresenceBroadcast;
    case 'Include room information in public lists':
      return l10n.roomConfPublic;
    case 'Enable this to allow people to find the room':
      return l10n.roomConfPublicDesc;
    case 'Description':
      return l10n.roomConfDesc;
    case 'A brief description of the room':
      return l10n.roomConfDescDesc;
    case 'Title':
      return l10n.roomConfName;
    case 'Password':
      return l10n.roomConfSecret;
    case 'Addresses (JIDs) of room occupants may be viewed by:':
      return l10n.roomConfWhois;
    case 'Maximum number of history messages returned by room':
      return l10n.roomConfHistoryLength;
    case 'Specify the maximum number of previous messages that should be sent to users when they join the room':
      return l10n.roomConfHistoryLengthDesc;
    case 'Default number of history messages returned by room':
      return l10n.roomConfDefaultHistory;
    case 'Specify the number of previous messages sent to new users when they join the room':
      return l10n.roomConfDefaultHistoryDesc;
    case 'Archive chat on server':
      return l10n.roomConfEnableArchiving;
    case 'URL where this room can be joined':
      return l10n.roomConfWebchatUrl;
    case 'Moderators only':
      return l10n.roomConfModeratorsOnly;
    case 'Anyone':
      return l10n.roomConfAnyone;
    case 'moderator':
      return l10n.roomConfModerator;
    case 'participant':
      return l10n.roomConfParticipant;
    case 'visitor':
      return l10n.roomConfVisitor;
    case 'none':
      return l10n.roomConfNone;
    case 'Always allow private messages to moderators':
      return l10n.roomConfAllowModPm;
    case 'Allow private messages from':
      return l10n.roomConfAllowPm;
    case 'Everyone':
      return l10n.roomConfEveryone;
    case 'Participants':
      return l10n.roomConfParticipants;
    case 'Moderators':
      return l10n.roomConfModerators;
    case 'Members':
      return l10n.roomConfMembers;
    case 'No one':
      return l10n.roomConfNoOne;
    default:
      return label;
  }
}
