// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// User-typed JID validation aligned with Conversations `Jid.ofUserInput`:
// parse address parts, then require a hostname (Unicode labels) or IP domain.
//
// XEP-0171 §4.2.2: a translation provider may be a bare bot JID or a domain
// component — a resource is not required.

/// Conversations `HOSTNAME_PATTERN` (Unicode letters/digits, optional trailing `.`).
final _hostnamePattern = RegExp(
  r'^(?=.{1,253}$)(?!-)[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?(?:\.(?!-)[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?)*\.?$',
  unicode: true,
);

final _ipv4Pattern = RegExp(
  r'^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$',
);

/// Characters Nodeprep forbids in the localpart (ASCII subset + controls).
final _localForbidden = RegExp(r'''["&'/:<>@\s\x00-\x1f\x7f]''');

/// Resourceprep: no ASCII controls or space for typed input.
final _resourceForbidden = RegExp(r'[\s\x00-\x1f\x7f]');

/// Parses and validates a user-typed JID like Conversations `Jid.ofUserInput`.
///
/// Returns the trimmed normalized string, or null when invalid. Accepts entity
/// bare/full JIDs and domain JIDs (components). Empty resource after `/` fails.
String? jidOfUserInput(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;

  final slash = t.indexOf('/');
  final rest = slash < 0 ? t : t.substring(0, slash);
  final resource = slash < 0 ? null : t.substring(slash + 1);
  if (slash >= 0 && (resource == null || resource.isEmpty)) return null;

  String? local;
  final String domainRaw;
  final at = rest.indexOf('@');
  if (at < 0) {
    domainRaw = rest;
  } else {
    if (at == 0 || at >= rest.length - 1) return null;
    if (rest.contains('@', at + 1)) return null;
    local = rest.substring(0, at);
    domainRaw = rest.substring(at + 1);
  }

  if (local != null && !_validLocalpart(local)) return null;
  if (resource != null && !_validResourcepart(resource)) return null;

  final domain = _normalizeDomain(domainRaw);
  if (domain == null) return null;

  final bare = local == null ? domain : '$local@$domain';
  return resource == null ? bare : '$bare/$resource';
}

/// Form helper on top of [jidOfUserInput].
///
/// Defaults match contact / room / login fields: entity bare JID (`local@domain`).
/// Pass [bareOnly]: false and [requireLocalpart]: false for XEP-0171 providers
/// (bot bare, domain component, or full JID are all allowed by the XEP).
String? completeJidCandidate(
  String raw, {
  bool bareOnly = true,
  bool requireLocalpart = true,
}) {
  final parsed = jidOfUserInput(raw);
  if (parsed == null) return null;
  if (bareOnly && parsed.contains('/')) return null;
  if (requireLocalpart && !parsed.contains('@')) return null;
  return parsed;
}

/// True when [raw] is empty (optional field) or a valid [completeJidCandidate].
bool jidInputOk(
  String raw, {
  bool bareOnly = true,
  bool requireLocalpart = true,
  bool allowEmpty = false,
}) {
  final t = raw.trim();
  if (t.isEmpty) return allowEmpty;
  return completeJidCandidate(
        t,
        bareOnly: bareOnly,
        requireLocalpart: requireLocalpart,
      ) !=
      null;
}

bool _validLocalpart(String local) {
  if (local.isEmpty || local.length > 1023) return false;
  if (_localForbidden.hasMatch(local)) return false;
  return true;
}

bool _validResourcepart(String resource) {
  if (resource.isEmpty || resource.length > 1023) return false;
  if (_resourceForbidden.hasMatch(resource)) return false;
  return true;
}

/// Hostname (Conversations pattern) or IP; strips a single trailing `.`.
String? _normalizeDomain(String domainRaw) {
  if (domainRaw.isEmpty || domainRaw.length > 1023) return null;
  var domain = domainRaw;
  if (domain.endsWith('.') && domain.length > 1) {
    domain = domain.substring(0, domain.length - 1);
  }
  if (domain.isEmpty) return null;

  if (_isIpDomain(domain)) return domain;
  if (_hostnamePattern.hasMatch(domain)) return domain;
  return null;
}

bool _isIpDomain(String domain) {
  final unbracketed = domain.startsWith('[') && domain.endsWith(']')
      ? domain.substring(1, domain.length - 1)
      : domain;
  if (_ipv4Pattern.hasMatch(unbracketed)) return true;
  return _looksLikeIpv6(unbracketed);
}

bool _looksLikeIpv6(String s) {
  if (s.isEmpty || s.contains(' ')) return false;
  if (!s.contains(':')) return false;
  final parts = s.split(':');
  if (parts.length < 3 || parts.length > 8) return false;
  for (final part in parts) {
    if (part.isEmpty) continue;
    if (part.length > 4) return false;
    if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(part)) return false;
  }
  return true;
}
