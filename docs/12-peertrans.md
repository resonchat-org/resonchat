# Peer Message Translation (`peertrans`)

1. Normative proto-XEP  
2. Non-normative ResonChat client notes  
3. Non-normative bot appendix  

---

# Part 1 — Proto-XEP: Peer Message Translation

**Title:** Peer Message Translation  
**Short Name:** peertrans  
**Namespace:** `urn:resonchat:peertrans:0`  
**Status:** ProtoXEP (ResonChat)  
**Type:** Standards Track  
**Dependencies:** XMPP Core, XMPP IM, [XEP-0171](https://xmpp.org/extensions/xep-0171.html), [XEP-0461](https://xmpp.org/extensions/xep-0461.html), [monocles PQ OMEMO2](https://codeberg.org/monocles/monocles_chat/src/branch/master/docs/proto-xep-omemo-pqxdh.md) (`urn:monocles:omemo-pq:1`, when E2EE)  

## 1. Abstract

This specification defines an unsolicited peer translation of a prior message:
an XEP-0171 Direct Translation payload on a separate message that replies to
the parent (XEP-0461) and carries a `<peertrans/>` marker. Supporting clients
attach the translation to the parent. No translation IQ service and no server
middleware are required.

## 2. Introduction

[XEP-0171](https://xmpp.org/extensions/xep-0171.html) covers Direct Translation
on the speaker’s own stanza and IQ request/response to a provider. Neither
fits a bot or human that publishes a translation *after* someone else speaks
in a MUC or 1:1 chat.

This document combines:

* XEP-0171 Direct Translation (destination bodies + `langtrans`), without a
  required source-language `<body/>` (the parent holds the original);
* XEP-0461 reply (including that XEP’s compatibility fallback);
* `<peertrans/>` for discovery and display ranking.

## 3. Requirements

1. Any participant MAY publish a translation of a prior message.
2. The payload MUST be XEP-0171 Direct Translation; a source-language `<body/>`
   MUST NOT be required.
3. Supporting receivers MUST attach a valid peertrans to the replied-to message.
4. When several peers translate the same parent into the same language,
   receivers select by `priority`, then earliest.
5. When the parent uses monocles PQ OMEMO2, the translation content MUST be
   protected under that profile (§7).

## 4. Discovering Support

If a client implements peer message translation, it MUST specify the
`urn:resonchat:peertrans:0` feature in its service discovery information
features as specified in [XEP-0030](https://xmpp.org/extensions/xep-0030.html)
and the Entity Capabilities profile specified in
[XEP-0115](https://xmpp.org/extensions/xep-0115.html).

```xml
<!-- Client requests information about a chat partner's client -->
<iq type='get'
    from='romeo@montague.lit/orchard'
    to='juliet@capulet.lit/balcony'
    id='info1'>
  <query xmlns='http://jabber.org/protocol/disco#info'/>
</iq>
```

```xml
<!-- Partner's client advertises support for peertrans -->
<iq type='result'
    to='romeo@montague.lit/orchard'
    from='juliet@capulet.lit/balcony'
    id='info1'>
  <query xmlns='http://jabber.org/protocol/disco#info'>
    …
    <feature var='urn:resonchat:peertrans:0'/>
    …
  </query>
</iq>
```

A sender MAY publish a peertrans stanza without verifying that every recipient
advertises the feature.

## 5. Use Cases

### 5.1 Marker

```xml
<peertrans xmlns='urn:resonchat:peertrans:0' priority='3'/>
```

| Attribute  | Use      | Description                          |
|------------|----------|--------------------------------------|
| `priority` | required | Non-negative integer; see clamp below |

If `priority` parses as an integer `n` with `0 ≤ n ≤ 9`, the effective
priority is `n`; otherwise it is `0`.

| priority | Meaning |
|----------|---------|
| 9 | Professional human |
| 8 | Informal / volunteer human |
| 7 | LLM, human-reviewed |
| 6 | Conventional MT, human-reviewed |
| 5 | LLM with conversation context |
| 4 | LLM without special context |
| 3 | Neural MT (DeepL / Google / LibreTranslate class) |
| 2 | Lighter / mid-quality NMT |
| 1 | Rule-based / dictionary MT |
| 0 | Unknown, unspecified, or clamped invalid |

Receivers MUST rank by effective priority only.

### 5.2 Translation payload (XEP-0171)

The stanza MUST include XEP-0171 Direct Translation marking. For each
`<translation destination_lang='…'/>` there MUST be a matching
`<body xml:lang='…'>`. `source_lang` SHOULD be set when known. `engine` and
`reviewed` follow XEP-0171.

A source-language `<body/>` MUST NOT be required. Senders SHOULD omit it.
Duplicate `xml:lang` bodies invalidate the peertrans payload.

### 5.3 Linking to the parent (XEP-0461)

The stanza MUST include a reply to the parent. Which `id` to use follows
[XEP-0461](https://xmpp.org/extensions/xep-0461.html#business-id).

```xml
<reply xmlns='urn:xmpp:reply:0' id='PARENT-ID' to='…'/>
```

Senders SHOULD include the reply compatibility fallback from
[XEP-0461 §3.1](https://xmpp.org/extensions/xep-0461.html#usecases-fallback)
(`> `-prefixed quote of the parent body, blank line, then the translation, with
matching `<fallback for='urn:xmpp:reply:0'/>` offsets). Receivers MUST strip
that range before using the remainder as the translation text.

A `<reply/>` without `<peertrans/>` is an ordinary reply and MUST NOT be
merged as peer translation. A `<peertrans/>` without a valid XEP-0171 Direct
payload or without `<reply/>` MUST be ignored for merging.

### 5.4 Example

```xml
<!-- Parent -->
<message type='groupchat' from='room@muc.example/alice' id='a1'>
  <body xml:lang='en'>Good morning</body>
  <origin-id xmlns='urn:xmpp:sid:0' id='a1'/>
  <stanza-id xmlns='urn:xmpp:sid:0' by='room@muc.example' id='S1'/>
</message>

<!-- Peer translation -->
<message type='groupchat' from='room@muc.example/bot' id='b1'>
  <body xml:lang='zh'>> Good morning

早上好</body>
  <x xmlns='urn:xmpp:langtrans'>
    <translation destination_lang='zh' source_lang='en' engine='DeepL'/>
  </x>
  <reply xmlns='urn:xmpp:reply:0' id='S1' to='room@muc.example/alice'/>
  <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'>
    <body start='0' end='16'/>
  </fallback>
  <peertrans xmlns='urn:resonchat:peertrans:0' priority='3'/>
  <origin-id xmlns='urn:xmpp:sid:0' id='b1'/>
  <store xmlns='urn:xmpp:hints'/>
</message>
```

### 5.5 Encrypted rooms (monocles PQ OMEMO2)

When the parent uses [monocles PQ OMEMO2](https://codeberg.org/monocles/monocles_chat/src/branch/master/docs/proto-xep-omemo-pqxdh.md):
outer stanza carries `<reply/>`, reply fallback, store hint, EME, `<encrypted/>`,
and a legacy body; that profile’s SCE `<content>` carries the destination
`<body xml:lang>`, `<x xmlns='urn:xmpp:langtrans'/>`, and `<peertrans/>`.

## 6. Business Rules

1. For each `(parent-id, destination-lang)`, show at most one translation.
2. Same bare sender: earliest wins; a later stanza without XEP-0308 is
   ignored; XEP-0308 replaces and MUST keep `peertrans`, `langtrans`, and
   reply to the same parent/language.
3. Among remaining candidates, highest effective `priority` wins; ties go to
   the earliest.
4. Merged peertrans MUST be displayed as attached to the parent, not as an
   independent bubble.
5. Do not treat a peertrans as the parent of another peertrans.
6. Deduplicate carbons/MAM by the peertrans stable id (origin-id preferred).
7. If the parent is not yet known, the receiver MAY buffer briefly.

## 7. Encryption

This protocol is defined only for:

* **Plaintext** parents — peertrans is plaintext 0171 + `langtrans` +
  `peertrans` + reply; supporting receivers MAY merge.
* **monocles PQ OMEMO2** parents — peertrans rides that profile’s SCE
  (`body` / `langtrans` / `peertrans` inside `<content>`; reply MAY stay
  outer); receivers decrypt, reinject, then merge.

Profiles that encrypt a single opaque payload and cannot carry multi-body
XEP-0171 / `peertrans` inside the ciphertext do **not** support peer
translation at all. Senders MUST NOT publish peertrans for such parents;
receivers have no peertrans semantics to apply.

A plaintext peertrans against an encrypted parent (or the reverse) is a
class mismatch and MUST be ignored for attachment (§8).

## 8. Security Considerations

`priority` is self-asserted. Clients MAY apply local policy (for example,
accept only MUC owner/admin). Cleartext translation of an encrypted parent
leaks content and MUST be ignored (§7).

## 9. XML Schema

```xml
<?xml version='1.0' encoding='UTF-8'?>
<xs:schema
    xmlns:xs='http://www.w3.org/2001/XMLSchema'
    targetNamespace='urn:resonchat:peertrans:0'
    xmlns='urn:resonchat:peertrans:0'
    elementFormDefault='qualified'>
  <xs:element name='peertrans'>
    <xs:complexType>
      <xs:attribute name='priority' type='xs:integer' use='required'/>
    </xs:complexType>
  </xs:element>
</xs:schema>
```

XEP-0171’s schema applies to `<x xmlns='urn:xmpp:langtrans'/>`.

## 10. XMPP Registrar Considerations

Namespace / feature: `urn:resonchat:peertrans:0`

---

# Part 2 — ResonChat client notes (non-normative)

* Trust: everyone (default), or MUC owner/admin only.
* Merge under the parent translation strip; no separate bubble.
* Strip reply compatibility fallback before merge.
* Parse after PQ/SCE reinject; candidates → winner in `message_translations`
  keyed by parent id; handle 0308, retract, early arrival.

---

# Part 3 — Bot appendix (non-normative)

* Destination body only + `source_lang` on `<translation/>`; no source body.
* `<reply/>` per XEP-0461; reply compatibility fallback as in §5.3.
* `<peertrans priority='…'/>` per §5.1 (e.g. NMT → `3`).
* Only plaintext or monocles PQ OMEMO2 parents; other E2EE has no peertrans.
* Revise with XEP-0308.
