// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// How much of the user's history the *server* is allowed to keep, and for how
// long (`urn:xmpp:mam:prefs:0`).
//
// This is the one setting in this client that is about somebody else's copy of
// the messages. Everything else in lib/ describes what this device may read or
// sign for; this describes what the server has been *asked* to do. Two things
// follow from that, and both are load-bearing in what follows:
//
//   1. A retention preference is an instruction, not a deletion. Nothing in
//      this protocol removes anything. Shortening retention stops the server
//      adding to what it holds; it does not empty it. A user who learns that
//      after changing the setting has been told something the setting cannot
//      deliver, so [warningsBeforeChange] says it beforehand.
//   2. A server that did not answer has not granted anything. "We do not know"
//      and "keep everything" are different states, and only one of them is a
//      permission. Every field the protocol leaves optional is optional here
//      too, and none of them defaults to the permissive reading — see the
//      comments on [MamPrefs.defaultRetention] and [MamPrefsSupport].
//
// That is the same position as `resolveTrack`, which blocks a send when the
// peer's device list cannot be read rather than treating the unreadable list
// as consent, and the same as `capabilities.dart`, which carries a `reliable`
// flag that is false when a fetch failed. Absence of evidence is never
// permission, and here it is specifically never "keep my history forever".
//
// Provenance, because the vocabulary here is wider than the standard's. The
// standardised form of this protocol (XEP-0441, in `urn:xmpp:mam:2`) carries a
// default policy plus an always/never list of JIDs, and deliberately leaves
// retention *duration* to an ad-hoc command. The dialect below adds the `max`
// day cap and the `only-muc` / `unlimited` policies. This file does not read
// one form as the other, and a policy token it does not recognise becomes an
// explicitly unrecognised policy rather than one of the values it does know —
// see [MamRetention.parse], which is the most important line in it.
//
// No imports, on purpose: the decision layer here is pure so the privacy
// sentences and the precedence rules can be tested without a connection, an XML
// tree or a database. The connection layer reduces a stanza to
// [MamPrefsElement] and hands it to [parseMamPrefs].

/// The wire vocabulary, in one place.
///
/// A caller assembling the stanza should not have to remember an element name,
/// and the names live next to the code that interprets them so the two cannot
/// drift apart.
abstract final class MamPrefsForm {
  /// The protocol namespace, on the `<prefs/>` element.
  static const String namespace = 'urn:xmpp:mam:prefs:0';

  /// The disco `var` a server advertises if it stores these preferences.
  ///
  /// Deliberately *not* `urn:xmpp:mam:2`. A server that advertises MAM queries
  /// is telling us it keeps an archive; that is the opposite privacy direction
  /// and must never be read as "and there is a setting for it".
  static const String feature = namespace;

  /// IQ type asking for the current preferences.
  static const String iqTypeGet = 'get';

  /// IQ type replacing them. Replaces, not merges — see
  /// [mayWritePreferences].
  static const String iqTypeSet = 'set';

  static const String prefsElement = 'prefs';

  /// `with` is a reserved word, so the constant cannot be.
  static const String withElement = 'with';

  static const String attrDefault = 'default';
  static const String attrMax = 'max';
  static const String attrJid = 'jid';
  static const String attrTo = 'to';
}

/// The bare form of [jid].
///
/// String surgery rather than a JID parse, deliberately. A JID from the server
/// that we cannot parse still has a bare form we can key on, and dropping an
/// override because its JID looked odd would hand that conversation back to the
/// account default — re-enabling archiving for exactly the person the user
/// switched it off for. A privacy setting that throws away the entries it could
/// not understand is a privacy setting that fails open.
String bareJid(String jid) {
  final slash = jid.indexOf('/');
  return slash == -1 ? jid : jid.substring(0, slash);
}

/// The archiving policies this client knows, ordered by how much history the
/// server is then permitted to keep.
///
/// The ordering is the point. Deciding whether a change shortens retention
/// means comparing any two policies, and a partial order would leave the
/// incomparable pairs to a judgement call — and the judgement call available to
/// someone in a hurry is always the permissive one ("we cannot show it got
/// shorter, so let it through"). [never] < [onlyMuc] < [roster] < [always] <
/// [unlimited] is monotone in exposure: group chats only is a subset of
/// contacts-on-the-roster, which is a subset of everything, and [unlimited] is
/// [always] with the day cap removed.
///
/// `days: N` is deliberately *not* a member. An enum constant cannot carry a
/// per-instance number, and giving the cap its own constant would put N in a
/// string that has to be re-parsed on every round trip through the server —
/// where one server that reformats or drops it silently changes what the user
/// believes their retention to be, and the failure is invisible because the
/// setting still looks set. The number is therefore a field on
/// [RetentionPolicy], the value that really is per-instance, and this enum stays
/// a closed set of the five named policies. The cost is one extra object; the
/// alternative is a number that survives nowhere.
enum MamRetention {
  never(0),
  onlyMuc(1),
  roster(2),
  always(3),
  unlimited(4);

  const MamRetention(this.exposure);

  /// Higher means the server is permitted to keep more. See [MamRetention].
  final int exposure;

  /// The token this policy appears as on the wire.
  String get token => switch (this) {
        MamRetention.never => 'never',
        MamRetention.onlyMuc => 'only-muc',
        MamRetention.roster => 'roster',
        MamRetention.always => 'always',
        MamRetention.unlimited => 'unlimited',
      };

  /// Reads a wire token, or null for one we do not know.
  ///
  /// Null, and never a default. An unrecognised token is the server telling
  /// us something we failed to understand, and mapping it onto [always] or
  /// [unlimited] would turn a parse failure into a privacy posture the user
  /// never chose — and one chosen on their behalf, which is the only kind of
  /// choice that is worse than no choice at all.
  static MamRetention? parse(String token) => switch (token) {
        'never' => MamRetention.never,
        'only-muc' => MamRetention.onlyMuc,
        'roster' => MamRetention.roster,
        'always' => MamRetention.always,
        'unlimited' => MamRetention.unlimited,
        _ => null,
      };
}

/// What the server has been told to keep, and for how long.
///
/// Every field is optional and the combinations are not equivalent, which is
/// the reason this is a class rather than a nullable enum. Read [policy] as
/// *which* messages, [maxDays] as *for how long*, and neither as a default:
///   * both set — the normal case.
///   * [maxDays] only — a cap with no stated policy. The server said how long
///     and not what. See [RetentionPolicy.days].
///   * [unrecognised] only — the server said what, in words we do not have.
///   * neither — the server stated nothing here.
class RetentionPolicy {
  RetentionPolicy({
    this.policy,
    this.unrecognised,
    this.maxDays,
  }) {
    if (policy != null && unrecognised != null) {
      throw ArgumentError(
        'a policy is either understood or not, not both',
      );
    }
    final days = maxDays;
    if (days != null && days < 1) {
      // Throwing rather than clamping. A caller who writes `days(0)` has
      // meant something by it, and the two available meanings — "keep nothing"
      // and "keep for a day" — are opposite privacy postures, so silently
      // choosing one of them is not available. The parser never reaches here:
      // it drops an unreadable cap to null instead, because a server's
      // malformed stanza must not be able to stop the client working. Asserts
      // and throws are for catching our own bugs; a hostile stanza gets a
      // recorded loss, never an exception.
      throw ArgumentError('maxDays must be at least 1, was $days');
    }
  }

  /// `days: N` — a retention cap with no statement of *which* messages.
  ///
  /// Reachable from `<prefs max='30'/>`. [policy] is null and deliberately so:
  /// pairing a bare cap with a guessed policy is how a server that answered one
  /// question gets recorded as having answered two.
  factory RetentionPolicy.days(int days) {
    if (days < 1) {
      throw ArgumentError('days must be at least 1, was $days');
    }
    return RetentionPolicy(maxDays: days);
  }

  /// Which messages the server archives, or null when it did not say.
  final MamRetention? policy;

  /// The token the server sent, when it stated a policy we do not know.
  ///
  /// Non-null means the server *did* say something and we failed to understand
  /// it, which is the opposite of [policy] being null. The two produce different
  /// sentences for the user and only one of them is an absence of information,
  /// so they must not share a representation.
  final String? unrecognised;

  /// The day cap, or null when none was stated or it could not be read.
  final int? maxDays;

  /// Whether the server has been told to keep nothing at all.
  ///
  /// True only for [MamRetention.never]. Every other state — a cap with no
  /// policy, a token we do not recognise, nothing at all — answers false,
  /// because the failure this getter can have is telling a user their history
  /// is not being kept when it is. That is worse than the opposite mistake: an
  /// unnecessary warning gets dismissed, a wrong reassurance gets believed.
  bool get keepsNothing => policy == MamRetention.never;

  /// How much the server is permitted to keep, or null when we cannot tell.
  ///
  /// Null is a real answer and has to stay distinguishable from a low rank:
  /// "we do not know" is not "keeps very little".
  int? get exposure => policy?.exposure;

  @override
  bool operator ==(Object other) =>
      other is RetentionPolicy &&
      other.policy == policy &&
      other.unrecognised == unrecognised &&
      other.maxDays == maxDays;

  @override
  int get hashCode => Object.hash(policy, unrecognised, maxDays);

  @override
  String toString() => 'RetentionPolicy(policy: $policy, '
      'unrecognised: $unrecognised, maxDays: $maxDays)';
}

/// The preferences for one account, as far as we know them.
///
/// Every field is nullable because the protocol's are, and unlike the protocol
/// none of them is filled in with a plausible value on our behalf. A caller
/// that needs a value here has to decide what its absence means, which is the
/// correct place for that decision.
class MamPrefs {
  /// Keys [overrides] by bare JID, so an override filed against
  /// `romeo@montague.lit/phone` is found by a lookup for `romeo@montague.lit`.
  ///
  /// Two entries differing only by resource would be two policies for one
  /// person, and which of them the server applied would be a server-side
  /// detail the user has no way to see.
  factory MamPrefs({
    String? resource,
    RetentionPolicy? defaultRetention,
    Map<String, RetentionPolicy> overrides = const {},
  }) =>
      MamPrefs._(
        resource: resource,
        defaultRetention: defaultRetention,
        overrides: {
          for (final entry in overrides.entries) bareJid(entry.key): entry.value,
        },
      );

  const MamPrefs._({
    this.resource,
    this.defaultRetention,
    this.overrides = const {},
  });

  /// The resource these preferences were read for, or null when the question
  /// was about the account as a whole.
  ///
  /// Null does not mean "the server said it applies everywhere": it means we
  /// did not ask about a resource, or the answer named none. An answer read for
  /// `me@example/phone` describes that resource's archive and must not be
  /// shown on another device's page — see [appliesToResource].
  final String? resource;

  /// What the server has been told to keep for conversations with no override.
  ///
  /// Null means the `<prefs/>` carried no `default`: the server is applying a
  /// policy of its own that it did not tell us. It emphatically does not mean
  /// [MamRetention.unlimited]. Reading it as unlimited would tell every user on
  /// a server that does not implement this that their entire history is being
  /// kept, when the truth is that nobody knows — and a privacy page that says
  /// "kept forever" about something it has not checked is worse than no page.
  final RetentionPolicy? defaultRetention;

  /// Per-conversation policies, keyed by bare JID.
  final Map<String, RetentionPolicy> overrides;

  /// The override for [conversation], or null when there is none.
  ///
  /// Null here and null in [defaultRetention] mean opposite things to the
  /// user, which is why this is separate from [effectiveRetention].
  RetentionPolicy? overrideFor(String conversation) =>
      overrides[bareJid(conversation)];

  /// This account's preferences with the default replaced.
  MamPrefs withDefault(RetentionPolicy? policy) => MamPrefs(
        resource: resource,
        defaultRetention: policy,
        overrides: overrides,
      );

  /// This account's preferences with [conversation]'s override set or removed.
  ///
  /// A null [policy] removes the override, which puts the conversation back on
  /// the account default — a change that usually *increases* what the server
  /// keeps, and so wants the same warning as any other lengthening.
  MamPrefs withOverride(String conversation, RetentionPolicy? policy) {
    final next = Map<String, RetentionPolicy>.of(overrides);
    if (policy == null) {
      next.remove(bareJid(conversation));
    } else {
      next[bareJid(conversation)] = policy;
    }
    return MamPrefs(
      resource: resource,
      defaultRetention: defaultRetention,
      overrides: next,
    );
  }
}

/// The policy governing one conversation: the override, else the default.
///
/// Precedence is the override, unconditionally, including when the override is
/// the more restrictive of the two. So "never" at conversation level beats
/// "always" at account level, and so does the reverse.
///
/// The tempting alternative is to let the account default win when it archives
/// less, on the theory that a global setting should not be defeated by a local
/// one. That reasoning produces an account the user can never have a private
/// conversation on, which is precisely the case the override exists for: it
/// would mean that turning on archiving for everyone silently re-archives the
/// one person who was excluded. An override is a replacement, not a refinement,
/// and a refinement that silently strengthens the server's hold is not one.
///
/// Returns null when neither an override nor a default was stated, and null is
/// the honest answer: it means the server applies a policy of its own that it
/// did not tell us, not that it applies a permissive one.
RetentionPolicy? effectiveRetention({
  required MamPrefs prefs,
  required String conversation,
}) =>
    prefs.overrideFor(conversation) ?? prefs.defaultRetention;

/// Whether [prefs] may be used as the picture for [resource].
///
/// A preferences answer is about one archive. Showing a resource-scoped answer
/// on another resource's page would report one device's privacy posture as
/// another's, and the user has no way to notice. Same reason `resolveTrack`
/// insists our own devices appear in the recipient sets: the fact has to be
/// about the thing being acted on.
bool appliesToResource(MamPrefs? prefs, String? resource) {
  if (prefs == null) return false;
  final scoped = prefs.resource;
  // An answer nobody scoped describes the account, and describes it for every
  // resource. One scoped to another resource describes neither this one nor the
  // account.
  return scoped == null || resource == null || scoped == resource;
}

/// True when [next] leaves the server keeping strictly less than [current].
///
/// False whenever the two cannot be ranked against each other — not because
/// they compare equal, but because "we cannot tell" is not evidence of a
/// reduction. Guessing here is available in one direction only and it is the
/// permissive one: an unrankable pair could be anything from "keeps nothing"
/// to "keeps everything for a year", so treating it as a reduction would warn
/// on every unrankable change, and treating it as an increase would stay quiet
/// through one.
///
/// The uncertainty does not go missing. It is carried by
/// [conversationPrivacySummary] of the *new* state, which says out loud what
/// the server failed to state — that is the sentence the user reads before
/// confirming, and a warning is not needed to duplicate it.
bool shortensRetention(RetentionPolicy? current, RetentionPolicy? next) {
  if (current == null || next == null) return false;

  // A cap on a `never` policy moves nothing, because nothing is kept either
  // way. Reporting a reduction here would put a privacy warning on a change
  // that cannot affect privacy at all, and warnings that fire on harmless
  // changes are warnings the user learns to dismiss.
  if (current.keepsNothing && next.keepsNothing) return false;

  final before = current.exposure;
  final after = next.exposure;
  if (before != null && after != null) {
    if (before != after) return after < before;
  } else if (before != after) {
    // One side states a policy and the other states only a cap, so there is no
    // honest comparison to make. Both null is not this case: two cap-only
    // policies compare fine, on their caps.
    return false;
  }
  return _isShorterCap(current.maxDays, next.maxDays);
}

/// A smaller cap shortens retention; a cap where there was none does not.
///
/// Absent is treated as unbounded, which is the only reading under which the
/// comparison is sound: a server that stopped quoting `max` has not told us it
/// keeps things for longer, it has told us less, and that case is warned about
/// separately rather than being counted as a lengthening.
bool _isShorterCap(int? current, int? next) {
  if (current == null) return next != null;
  if (next == null) return false;
  return next < current;
}

/// One element of the preferences form, as far as this file is concerned.
///
/// The connection layer walks the XML and produces these; nothing here touches
/// a parser. An element carries its namespace because a stanza can contain
/// children from several namespaces, and reading a `<prefs/>` from the wrong
/// one is how a MAM query form ends up read as a retention setting.
class MamPrefsElement {
  const MamPrefsElement(
    this.name, {
    this.namespace = MamPrefsForm.namespace,
    this.attributes = const {},
    this.children = const [],
  });

  final String name;
  final String namespace;
  final Map<String, String> attributes;
  final List<MamPrefsElement> children;

  String? attribute(String name) => attributes[name];

  /// The element as XML, for logs and for asserting a round trip in a test.
  ///
  /// Not a builder: a real stanza goes through moxxmpp's XMLNode. This exists
  /// so a test can compare what went out with what comes back, which is the
  /// only way the claim "the number survives the server" is checked rather than
  /// asserted.
  String toXml() {
    final attrs = [
      for (final entry in attributes.entries)
        "${entry.key}='${entry.value}'",
    ];
    final open = "<$name${attrs.isEmpty ? '' : ' ${attrs.join(' ')}'}";
    if (children.isEmpty) return '$open/>';
    return '$open>${children.map((c) => c.toXml()).join()}</$name>';
  }

  @override
  String toString() => toXml();
}

/// Reads a `<prefs/>` element, or returns null if this is not one.
///
/// Null means "this element is not the preferences form" and never "the
/// preferences form was empty". The two lead to opposite screens — one says the
/// server cannot do this at all, the other says everything is at its default —
/// and conflating them either hides a control that works or invents one that
/// does not.
MamPrefs? parseMamPrefs(
  MamPrefsElement element, {
  String? resource,
}) {
  if (element.name != MamPrefsForm.prefsElement) return null;
  if (element.namespace != MamPrefsForm.namespace) return null;

  final overrides = <String, RetentionPolicy>{};
  for (final child in element.children) {
    // An element we do not recognise is not evidence of anything and must not
    // cost us the elements we did read: a server extending the form should not
    // turn into "we have no preferences".
    if (child.namespace != MamPrefsForm.namespace) continue;
    if (child.name != MamPrefsForm.withElement) continue;

    // A `<with/>` naming no JID cannot be applied to any conversation. Dropping
    // it is the only option and dropping it is permissive — it puts whoever it
    // was meant for back on the account default — so it is commented rather
    // than left to look like a harmless skip. The honest response to a
    // malformed stanza is to stop, not to guess which conversation was meant,
    // and stopping here means one conversation silently loses its exclusion.
    final jid = child.attribute(MamPrefsForm.attrJid);
    if (jid == null || jid.isEmpty) continue;

    // Recorded even when the policy inside it is unreadable. Leaving the entry
    // out would mean "falls back to the account default", which is a different
    // and more permissive claim than "the server said something about this
    // conversation that we cannot describe".
    overrides[jid] = parseRetention(
      child.attribute(MamPrefsForm.attrDefault),
      max: child.attribute(MamPrefsForm.attrMax),
    );
  }

  final stated = element.attributes.containsKey(MamPrefsForm.attrDefault) ||
      element.attributes.containsKey(MamPrefsForm.attrMax);
  return MamPrefs(
    // The IQ's `to` is authoritative; the element's own `to` is a fallback for
    // a server that names it there.
    resource: resource ?? element.attribute(MamPrefsForm.attrTo),
    defaultRetention: stated
        ? parseRetention(
            element.attribute(MamPrefsForm.attrDefault),
            max: element.attribute(MamPrefsForm.attrMax),
          )
        : null,
    overrides: overrides,
  );
}

/// Reads one policy off the wire.
///
/// Always returns something, because the three things that can go wrong here
/// are three different states and each has its own sentence. Collapsing any of
/// them into null hands the caller a decision with no information behind it,
/// and null is what every caller treats as "the server did not say" — the most
/// permissive thing this module is able to express.
RetentionPolicy parseRetention(String? token, {String? max}) {
  final policy = token == null ? null : MamRetention.parse(token);
  return RetentionPolicy(
    policy: policy,
    unrecognised: policy == null && token != null ? token : null,
    maxDays: _parseMax(max),
  );
}

/// A cap we cannot read is left out.
///
/// Leaving it out makes the summary report the period as unknown, which is the
/// point: a server sending `max='0'` or `max='soon'` has told us it intended a
/// limit, and inventing one — "forever", or "zero days" — is worse than
/// admitting we lost the number. Note that this is the one place a value is
/// discarded, and it is discarded towards the *less* informative reading
/// rather than the more permissive one.
int? _parseMax(String? raw) {
  final value = raw == null ? null : int.tryParse(raw);
  if (value == null || value < 1) return null;
  return value;
}

/// The `<prefs/>` element for an iq-set, and the one an iq-get asks for.
///
/// [MamPrefs] is the *whole* desired state, because the set form replaces what
/// the server holds rather than merging into it. A caller therefore edits a
/// read and never builds one from a guess — see [mayWritePreferences].
MamPrefsElement toPrefsElement(MamPrefs prefs) {
  final policy = prefs.defaultRetention;
  final jids = prefs.overrides.keys.toList()..sort();
  return MamPrefsElement(
    MamPrefsForm.prefsElement,
    attributes: {
      if (policy != null) ..._policyAttributes(policy),
      if (prefs.resource != null) MamPrefsForm.attrTo: prefs.resource!,
    },
    children: [
      // Sorted, because a form whose element order depends on a Map's internal
      // iteration is a form that produces a different stanza and a different
      // log line for the same settings.
      for (final jid in jids)
        MamPrefsElement(
          MamPrefsForm.withElement,
          attributes: {
            MamPrefsForm.attrJid: jid,
            ..._policyAttributes(prefs.overrides[jid]!),
          },
        ),
    ],
  );
}

Map<String, String> _policyAttributes(RetentionPolicy policy) => {
      // An unrecognised token goes back out as itself rather than being dropped.
      // Dropping it would turn the server's word into silence on the round trip
      // and, if the caller echoed the result back, into a `set` that quietly
      // removes a setting this client cannot even name.
      if (policy.unrecognised != null)
        MamPrefsForm.attrDefault: policy.unrecognised!,
      if (policy.policy != null)
        MamPrefsForm.attrDefault: policy.policy!.token,
      if (policy.maxDays != null) MamPrefsForm.attrMax: '${policy.maxDays}',
    };

/// What we know about whether this server stores these preferences.
///
/// Three states, because the user-facing consequences are three: a server that
/// implements this has a control, a server that does not has *no* control
/// (which is itself worth saying, and is not the same as having one we cannot
/// see), and a server we have not asked has nothing to say yet.
///
/// Collapsing [unknown] into [supported] is the failure this module exists to
/// avoid. It is the failure `resolveTrack` guards against when a device list
/// cannot be read, and the failure `capabilities.dart` guards against with
/// `reliable: false`: an unreadable answer is not a permissive answer. Here it
/// would be a permissive one with a UI attached, so the user would be shown a
/// retention control whose effect nobody has confirmed.
enum MamPrefsSupport {
  unknown,
  unsupported,
  supported;

  /// Whether a `set` should be expected to take effect on the server.
  ///
  /// False for [unsupported] and [unknown] alike; they fail differently.
  /// [unsupported] means the change will certainly not take effect, [unknown]
  /// means we cannot tell. `blocking.dart` draws the same line when it writes
  /// the local block before asking the server: honouring the user's decision on
  /// this device is right in both cases, and reporting that the server refused
  /// is right in only one.
  bool get honoured => this == MamPrefsSupport.supported;
}

/// The one question this module is asked about support, phrased so that the
/// wrong answer is not the convenient one.
bool serverSupportsMamPrefs(MamPrefsSupport support) =>
    support == MamPrefsSupport.supported;

/// Support as read from service discovery.
///
/// [featuresReadable] false means the discovery answer never arrived. An empty
/// list and an unreadable list both mean "we found no `var`", and treating them
/// the same would tell every user on a slow network that their server has no
/// archive control at all. `capabilities.dart` marks that case
/// `reliable: false` for exactly this reason.
MamPrefsSupport supportFromFeatures(
  Iterable<String> features, {
  required bool featuresReadable,
}) {
  if (!featuresReadable) return MamPrefsSupport.unknown;
  return features.contains(MamPrefsForm.feature)
      ? MamPrefsSupport.supported
      : MamPrefsSupport.unsupported;
}

/// Whether the current state is one we may write over.
///
/// Two independent reasons to say no, and neither of them is "send it and see":
///
///   * We have not read the current preferences. The set form replaces rather
///     than merges, so a `set` built from a partial picture erases the
///     overrides we never saw. Writing over state we have not read is not a
///     privacy improvement; it is an unreviewed change made on the user's
///     behalf, and it is the one way this module could *cause* the harm it
///     exists to prevent.
///   * The server does not store these preferences. Sending the set is
///     harmless, but the change would then be a claim with nothing behind it.
///
/// The first is the reason this is a separate function rather than a check
/// inside [warningsBeforeChange]: the caller has to be able to ask "may I even
/// try this" before it has anything to warn about.
bool mayWritePreferences({
  required MamPrefsSupport support,
  required MamPrefs? current,
}) =>
    support == MamPrefsSupport.supported && current != null;

/// Why a change needs saying out loud before it is applied.
enum MamChangeKind {
  /// The new instruction leaves the server keeping strictly less than the old
  /// one — which is not the same as it having less.
  shorterRetention,

  /// We do not know what the server is keeping now, so the direction of the
  /// change cannot be stated in either direction.
  unknownCurrent,

  /// The server has not confirmed it stores these preferences, so the change
  /// may not take effect at all.
  mayNotTakeEffect,
}

/// Something the user must be told before a retention change is applied.
class MamChangeWarning {
  const MamChangeWarning(this.kind, this.title, this.consequence, {
    required this.needsConfirmation,
  });

  /// The wording is fixed here rather than in the widget so it can be reviewed
  /// — and tested — without rendering anything. It is also the only place in
  /// this file allowed to be certain about the server's future behaviour, and
  /// even here it says what the server was *asked* to do.
  const MamChangeWarning.shorterRetention()
      : this(
          MamChangeKind.shorterRetention,
          'Shortening retention does not delete what the server already has',
          'This applies from now on. Messages the server has already stored are '
              'not deleted because of it — the server drops them only as they '
              'age past the new limit, in its own time, and it may never do '
              'that at all.',
          needsConfirmation: true,
        );

  const MamChangeWarning.unknownCurrent()
      : this(
          MamChangeKind.unknownCurrent,
          'We do not know what this server is already keeping',
          'It did not answer when we asked, so this change cannot be called an '
              'increase or a decrease. Nothing on this screen tells you what '
              'is already stored.',
          needsConfirmation: false,
        );

  /// [support] distinguishes "cannot" from "have not found out", because the
  /// user's next move is different: for one there is no setting to change, for
  /// the other there may be one waiting on a better connection.
  factory MamChangeWarning.mayNotTakeEffect(MamPrefsSupport support) =>
      switch (support) {
        MamPrefsSupport.unsupported => const MamChangeWarning(
            MamChangeKind.mayNotTakeEffect,
            'This server does not keep archive preferences',
            'It did not advertise the feature, so there is no setting here to '
                'change. This app cannot tell the server to keep less; only '
                'whoever runs the server can.',
            needsConfirmation: true,
          ),
        // An unknown-support warning is deliberately not asking for
        // confirmation. It is not confirming a change, it is reporting that we
        // cannot confirm one, and a dialog that blocks every edit while the
        // server is quiet trains the user to dismiss dialogs — including the
        // one above, which is the one that matters.
        _ => const MamChangeWarning(
            MamChangeKind.mayNotTakeEffect,
            'We could not find out whether this server keeps archive '
                'preferences',
            'The setting may not be doing anything. Ask again when you are '
                'connected: if this still says so, it did not take effect.',
            needsConfirmation: false,
          ),
      };

  final MamChangeKind kind;
  final String title;
  final String consequence;

  /// Whether this should be a dialog the change waits on, rather than a line
  /// on the page.
  final bool needsConfirmation;
}

/// Everything that has to be said before a change is applied.
///
/// A list, not a single warning: one change can be shorter *and* unverifiable,
/// and a function that returned only one of them would have thrown the other
/// away. Most consequential first.
///
/// Note what this does not do. It does not block the change — that is
/// [mayWritePreferences]'s job, and blocking a decision the user was told
/// about and made anyway is the same objection `resolveTrack` raises about
/// refusing plaintext. It says the thing out loud and gets out of the way.
List<MamChangeWarning> warningsBeforeChange({
  required RetentionPolicy? current,
  required RetentionPolicy next,
  required MamPrefsSupport support,
}) {
  final warnings = <MamChangeWarning>[];
  if (current == null) {
    warnings.add(const MamChangeWarning.unknownCurrent());
  } else if (shortensRetention(current, next)) {
    warnings.add(const MamChangeWarning.shorterRetention());
  }
  if (support != MamPrefsSupport.supported) {
    warnings.add(MamChangeWarning.mayNotTakeEffect(support));
  }
  return warnings;
}

/// The line that belongs under every summary in this file.
///
/// It is here rather than in a widget because it is part of the claim. The
/// protocol has no deletion semantics at all, so a screen showing a retention
/// setting without this sentence is showing a promise the setting cannot keep.
const String mamPrefsCaveat =
    'This is what the server has been told to do. It does not delete anything '
    'the server is already holding.';

/// What each policy archives, in the words a settings page uses.
///
/// Noun phrases, not sentences. The tense and the agency are added by
/// [_summarise], which is the only place allowed to claim that the server was
/// asked for something — the difference between "is keeping" and "has been told
/// to keep" is the whole difference between a claim and a report, and it is too
/// easy to lose in a string literal.
extension MamRetentionWording on MamRetention {
  String get archives => switch (this) {
        MamRetention.never => 'none of your messages',
        MamRetention.onlyMuc => 'only your group chat messages',
        MamRetention.roster =>
          'only messages with people on your contact list',
        MamRetention.always => 'a copy of all your messages',
        MamRetention.unlimited => 'a copy of all your messages',
      };
}

/// One sentence about the whole account: what the server has been told to keep,
/// and for how long.
///
/// The wording rules, because a privacy summary is a claim about somebody
/// else's storage and the wrong words here are worse than no summary at all:
///
///   * Name the period, always. "and has not said when it will delete them"
///     is the answer when there is no cap. Leaving the period out is what makes
///     a sentence read as "indefinitely" when the server said nothing at all.
///   * No hedging — no "may", no "might". A sentence the user cannot decide
///     from is decoration, and the decision is theirs.
///   * Never imply a deletion. Nothing in this protocol removes anything, so no
///     sentence here says something is gone or will be removed; [mamPrefsCaveat]
///     carries that once, for every screen.
///   * Never claim an outcome the server has not confirmed. The subject is what
///     the server has been *told*, which is the only thing we actually know.
String privacySummary(MamPrefs prefs) =>
    _summarise(prefs.defaultRetention, 'The server has been told to keep');

/// One sentence about one conversation.
///
/// Says so when the answer comes from the account default, because "the server
/// has been told to keep nothing" and "the server has been told to keep
/// nothing, and not here either" are different facts and the second one is the
/// one a user in that conversation is asking about.
String conversationPrivacySummary(MamPrefs prefs, String conversation) {
  final override = prefs.overrideFor(conversation);
  return override != null
      ? _summarise(
          override,
          'In this conversation, the server has been told to keep',
        )
      : _summarise(
          prefs.defaultRetention,
          'In this conversation, as everywhere else, the server has been told '
              'to keep',
        );
}

String _summarise(RetentionPolicy? policy, String subject) {
  if (policy == null) {
    return 'The server has not said what it keeps, or for how long.';
  }

  final unknown = policy.unrecognised;
  if (unknown != null) {
    // The token is quoted rather than described, because "a policy this app
    // does not understand" is only actionable if the user can read the thing
    // that was not understood and go and ask about it.
    return 'The server asked for a storage policy called "$unknown" that this '
        'app does not understand, so what it keeps, and for how long, is '
        'unknown.';
  }

  final days = policy.maxDays;
  final kind = policy.policy;

  if (kind == null) {
    // A cap with no policy: the server answered half the question, and the half
    // it left out is the half that says whether the cap applies to everything.
    // Reporting only the cap here would read as "keeps your messages for 30
    // days", which is a policy the server never stated.
    if (days == null) {
      return 'The server has not said what it keeps, or for how long.';
    }
    return 'The server has said it keeps some of your messages for '
        '${_days(days)}, but has not said which.';
  }

  if (policy.keepsNothing) {
    // The one case where nothing needs qualifying. A day cap on a policy that
    // keeps nothing is meaningless, and naming one would read as a promise
    // about something that is not kept.
    return '$subject none of your messages.';
  }

  final period = _period(days, kind);
  return '$subject ${kind.archives} $period.';
}

/// The clause that answers "for how long".
///
/// [unlimited] is the one policy whose token *is* a statement about time, so
/// for it an absent cap is a period rather than a silence. For every other
/// policy, no cap means the server did not say — which is stated as such rather
/// than left as an absence, because an absence reads as "indefinitely" and
/// "indefinitely" is the one reading this file refuses to invent.
///
/// A cap alongside [MamRetention.unlimited] is kept, not reconciled away. The
/// two look contradictory and may well be redundant rather than contradictory
/// ("unlimited" about volume, `max` about age), so the cap wins: assuming no
/// cap is the only reading under which a user who set a limit is told they
/// have none.
String _period(int? days, MamRetention kind) {
  if (days != null) return 'for ${_days(days)}';
  if (kind == MamRetention.unlimited) return 'with no limit on how long';
  return ', and has not said when it will delete them';
}

String _days(int n) => n == 1 ? '1 day' : '$n days';
