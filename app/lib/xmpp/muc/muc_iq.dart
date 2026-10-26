// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MUC owner/admin IQ XML builders and parsers (XEP-0045).

import 'package:moxxmpp/moxxmpp.dart';

import 'package:resonchat/xmpp/muc/muc.dart';

/// `<query xmlns='…muc#owner'><destroy/></query>`
XMLNode mucOwnerDestroyQuery() => XMLNode.xmlns(
  tag: 'query',
  xmlns: mucOwnerXmlns,
  children: [XMLNode(tag: 'destroy')],
);

/// Empty `<query xmlns='…muc#owner'/>` (get config form).
XMLNode mucOwnerGetQuery() => XMLNode.xmlns(tag: 'query', xmlns: mucOwnerXmlns);

/// Owner set with a submitted data form.
XMLNode mucOwnerSubmitQuery(DataForm form) => XMLNode.xmlns(
  tag: 'query',
  xmlns: mucOwnerXmlns,
  children: [form.toSubmitXml()],
);

/// Owner set cancelling an open config form.
XMLNode mucOwnerCancelQuery() => XMLNode.xmlns(
  tag: 'query',
  xmlns: mucOwnerXmlns,
  children: [
    XMLNode.xmlns(
      tag: 'x',
      xmlns: dataFormsXmlns,
      attributes: {'type': 'cancel'},
    ),
  ],
);

/// Parse a config data form from a muc#owner result IQ, or null.
DataForm? parseMucOwnerConfigForm(XMLNode result) {
  final query = result.firstTag('query', xmlns: mucOwnerXmlns);
  final x = query?.firstTag('x', xmlns: dataFormsXmlns);
  if (x == null) return null;
  return parseDataForm(x);
}

/// Admin set affiliation for [userBareJid] (optional ban [reason]).
XMLNode mucAdminSetAffiliationQuery({
  required String userBareJid,
  required String affiliation,
  String? reason,
}) => XMLNode.xmlns(
  tag: 'query',
  xmlns: mucAdminXmlns,
  children: [
    XMLNode(
      tag: 'item',
      attributes: {'jid': userBareJid, 'affiliation': affiliation},
      children: [
        if (reason != null && reason.trim().isNotEmpty)
          XMLNode(tag: 'reason', text: reason.trim()),
      ],
    ),
  ],
);

/// Admin set role for [nick].
XMLNode mucAdminSetRoleQuery({required String nick, required String role}) =>
    XMLNode.xmlns(
      tag: 'query',
      xmlns: mucAdminXmlns,
      children: [
        XMLNode(tag: 'item', attributes: {'nick': nick, 'role': role}),
      ],
    );

/// Admin get items with [affiliation].
XMLNode mucAdminGetAffiliationQuery(String affiliation) => XMLNode.xmlns(
  tag: 'query',
  xmlns: mucAdminXmlns,
  children: [
    XMLNode(tag: 'item', attributes: {'affiliation': affiliation}),
  ],
);

/// Occupants listed in a muc#admin result IQ.
List<Occupant> parseMucAdminOccupants(XMLNode result) {
  final query = result.firstTag('query', xmlns: mucAdminXmlns);
  if (query == null) return const [];
  final out = <Occupant>[];
  for (final item in query.findTags('item')) {
    final o = occupantFromAdminItem(item);
    if (o != null) out.add(o);
  }
  return out;
}
