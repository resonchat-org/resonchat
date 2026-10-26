// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How much of the user's history the *server* is allowed to keep
// (XEP-0414, `urn:xmpp:mam:prefs:0`).
//
// This is the only setting in the client that is about somebody else's copy of
// the messages, so the register of these tests is the posture the module
// *refuses* to take, not the one it implements. Three failures are worth more
// here than a green suite:
//
//   * "the server did not say" collapsing into "keep everything", so a summary
//     says "kept forever" about an archive nobody has checked;
//   * a day cap that does not survive the round trip, leaving the setting
//     looking set while the number the user chose is gone;
//   * a change that shortens retention going unannounced, which teaches the
//     opposite lesson from the one the module's own warning exists to teach.
//
// The sweeps are exhaustive over the reachable state space (42
// [RetentionPolicy] values, 1764 ordered pairs) wherever the space is small
// enough to enumerate. A predicate that is only spot-checked fails on exactly
// the combination nobody wrote a case for, and the pairs nobody wrote a case
// for are where the module's two rules about *unknown* meet each other.
//
// Six assertions below are believed correct and contradict the module as
// written. They are marked FINDING and are left failing rather than weakened to
// match the code. Five defects, in six tests — one defect is asserted both by a
// named case and by an exhaustive sweep:
//
//   1. `appliesToResource` accepts a resource-scoped answer as the account's
//      picture, which is the reporting-one-device-as-another failure the
//      function's own comment names;
//   2. `shortensRetention` cannot rank a cap-only state against `never`, so the
//      most restrictive change in the protocol says nothing at all;
//   3. `shortensRetention` ranks a current that carries *no readable
//      information* against a stated cap, and `warningsBeforeChange` then
//      reports the change as a shortening instead of offering the
//      "we do not know" warning that exists for exactly this position
//      (two tests: one swept over every pair, one named);
//   4. `conversationPrivacySummary` is byte-identical to `privacySummary`
//      whenever the account default stated no recognisable policy, so a user in
//      that conversation cannot tell whose answer they are reading;
//   5. a `<with jid='  '/>` is kept rather than dropped, though it names no
//      conversation any more than an empty one does.

import 'package:test/test.dart';

import 'package:resonchat/xmpp/mam_prefs.dart';

void main() {
  const juliet = 'juliet@capulet.lit';
  const julietPhone = 'juliet@capulet.lit/phone';
  const julietTablet = 'juliet@capulet.lit/tablet';

  // ---------------------------------------------------------------------
  // The state space, named once so every sweep below is the same sweep.
  // ---------------------------------------------------------------------

  /// Caps that matter: none, the smallest a user can mean, and large ones.
  const dayCaps = <int?>[null, 1, 7, 30, 365, 3650];

  /// Every policy slot, including the null that means "the server did not say".
  final policies = <MamRetention?>[null, ...MamRetention.values];

  /// The whole reachable state space of a [RetentionPolicy].
  ///
  /// 6 caps x 6 policy slots = 36 understood states, plus 6 states carrying a
  /// token we cannot name: 42 in all. The count is asserted at the bottom of
  /// this file so a later edit that shrinks this list cannot quietly shrink
  /// every test that sweeps it.
  final states = <RetentionPolicy>[
    for (final cap in dayCaps)
      for (final policy in policies)
        RetentionPolicy(policy: policy, maxDays: cap),
    for (final cap in dayCaps)
      RetentionPolicy(unrecognised: 'weird', maxDays: cap),
  ];

  /// Both directions of the comparison `shortensRetention` is asked to make.
  Iterable<List<RetentionPolicy>> everyPair() sync* {
    for (final a in states) {
      for (final b in states) {
        yield [a, b];
      }
    }
  }

  RetentionPolicy state(
    MamRetention? policy, {
    int? maxDays,
    String? unrecognised,
  }) => RetentionPolicy(
    policy: policy,
    maxDays: maxDays,
    unrecognised: unrecognised,
  );

  /// Whether a state says anything at all. The one state that does not is
  /// unreachable on the wire, so it cannot survive a round trip.
  bool carriesSomething(RetentionPolicy p) =>
      p.policy != null || p.unrecognised != null || p.maxDays != null;

  /// [MamPrefs] with a default and nothing else, which is how the module is
  /// used everywhere.
  MamPrefs prefsWith(
    RetentionPolicy? defaultRetention, {
    Map<String, RetentionPolicy> overrides = const {},
  }) => MamPrefs(defaultRetention: defaultRetention, overrides: overrides);

  /// What a server that stated no default at all leaves us with: not a policy,
  /// not a period, and *nothing to summarise*.
  final unwritten = <MamPrefs>[MamPrefs()];

  /// States where the server stated a period but not a policy: the only two
  /// things it said are "something" and "for this long".
  final capOnly = states
      .where(
        (p) => p.policy == null && p.unrecognised == null && p.maxDays != null,
      )
      .toList();

  /// States that state no recognisable policy at all. Any summary built from
  /// one of these is assembled without its subject, which is where the
  /// FINDING below about conversation summaries comes from.
  final noReadablePolicy = states.where((p) => p.policy == null).toList();

  /// `never`, with and without a cap, which the wire form allows and this file
  /// calls meaningless but never discards.
  final neverVariants = <RetentionPolicy>[
    state(MamRetention.never),
    state(MamRetention.never, maxDays: 3650),
  ];

  /// The spellings of "no policy token" a stanza can carry.
  const tokens = <String?>[
    null,
    '',
    'never',
    '  ',
    'urgent',
    'ALWAYS',
    'always ',
  ];

  /// The spellings of "no JID" a `<with/>` can carry.
  const missingJids = <String?>[null, ''];

  /// Caps a server can send, with what may be read out of each. Deliberately
  /// including the ones that *do* parse, so the test cannot pass by discarding
  /// everything.
  const readCaps = <String?, int?>{
    null: null,
    '': null,
    '0': null,
    '-1': null,
    'soon': null,
    '1.5': null,
    '30 days': null,
    ' 30': null,
    '30 ': null,
    '007': 7,
    '1': 1,
    '30': 30,
    '1000000': 1000000,
  };

  /// Elements to put inside a `<prefs/>` that are not policy statements.
  final elements = <MamPrefsElement>[
    const MamPrefsElement(
      MamPrefsForm.withElement,
      attributes: {
        MamPrefsForm.attrJid: juliet,
        MamPrefsForm.attrDefault: 'never',
      },
    ),
    const MamPrefsElement('message'),
    const MamPrefsElement('subject'),
  ];

  void expectShorterWarning(List<MamChangeWarning> warnings, String what) {
    expect(
      warnings.map((w) => w.kind),
      contains(MamChangeKind.shorterRetention),
      reason: what,
    );
  }

  void expectNoShorterWarning(List<MamChangeWarning> warnings, String what) {
    expect(
      warnings.map((w) => w.kind),
      isNot(contains(MamChangeKind.shorterRetention)),
      reason: what,
    );
  }

  // ---------------------------------------------------------------------
  group('an absent field is not "unlimited"', () {
    test('a default nobody stated is not the most permissive reading', () {
      // The most expensive mistake available to this module. A server that
      // does not implement the form carries no `default` attribute, and
      // reading that as `unlimited` would tell every user on such a server
      // that their whole history is being kept, forever, under a policy nobody
      // ever wrote.
      for (final prefs in unwritten) {
        expect(prefs.defaultRetention, isNull, reason: 'no attribute at all');
        expect(
          effectiveRetention(prefs: prefs, conversation: juliet),
          isNull,
          reason: 'no attribute at all',
        );
        expect(
          privacySummary(prefs),
          isNot(contains('forever')),
          reason: 'an unstated default must not read as permanent',
        );
      }
    });

    test('and the server saying "unlimited" is a different value entirely', () {
      // The other direction. If "did not say" and "said keep everything" were
      // ever the same object, a user who has explicitly chosen unlimited and a
      // user on a server that knows nothing would be indistinguishable, and
      // the interface could not tell a real setting from a gap.
      final said = prefsWith(state(MamRetention.unlimited));
      // Both "no default attribute at all" and "a default we could not read",
      // because `<prefs/>`, `<prefs max='soon'/>` and `<prefs default='weird'/>`
      // are three different ways a server can fail to state its posture and
      // none of them is the user having chosen to keep everything.
      final notSaid = <MamPrefs>[
        ...unwritten,
        for (final p in states.where((p) => p.policy == null)) prefsWith(p),
      ];
      for (final prefs in notSaid) {
        expect(
          privacySummary(prefs),
          isNot(privacySummary(said)),
          reason: '"not stated" must not read as "unlimited"',
        );
        expect(
          conversationPrivacySummary(prefs, juliet),
          isNot(privacySummary(said)),
          reason: '"not stated" must not read as "unlimited"',
        );
      }
    });

    test('no state produces an indefinite reading except `unlimited`', () {
      // Swept, because the failure is a *sentence*, and the sentence is
      // assembled from four branches. An omission in any one of them shows up
      // as a user believing their history is permanent.
      for (final p in states) {
        final summary = privacySummary(prefsWith(p));
        expect(
          summary.contains('with no limit on how long'),
          p.policy == MamRetention.unlimited &&
              p.maxDays == null &&
              p.unrecognised == null,
          reason: '$p summarised as "$summary"',
        );
        // The token is interpolated from the server, so it can contain
        // anything; the client's own words cannot.
        if (p.unrecognised == null) {
          expect(
            RegExp(r'forever|indefinite|for ever|no time limit')
                .hasMatch(summary),
            isFalse,
            reason: '$p invented a period: "$summary"',
          );
        }
      }
    });

    test('an unknown token is never read as one of the policies', () {
      // A default return in `MamRetention.parse` would turn a parse failure into
      // a posture the user never chose, and one chosen on their behalf. Null
      // is the only safe answer, for every spelling of a token we do not know.
      for (final token in const [
        '',
        'NEVER',
        'Never',
        'always ',
        ' always',
        'unlimited\n',
        'only_muc',
        'all',
        'everything',
        'urn:xmpp:mam:2',
        '30',
        'x-unknown',
      ]) {
        expect(MamRetention.parse(token), isNull, reason: 'token "$token"');
      }
    });

    test('the unknown token survives as the server worded it', () {
      // Not dropped and not normalised. Dropping it would make a read and a
      // write disagree, and the difference would only show up on the server.
      final parsed = parseRetention('weird-policy');
      expect(parsed.policy, isNull);
      expect(parsed.unrecognised, 'weird-policy');
      expect(parsed.keepsNothing, isFalse);
      expect(parsed.exposure, isNull);
      expect(privacySummary(prefsWith(parsed)), contains('"weird-policy"'));
    });

    test('and it is not read as keeping nothing either', () {
      // The reassuring direction, which is the one that hurts. `keepsNothing`
      // is what an interface would use to hide an archive control; getting it
      // wrong on an unreadable token tells a user their messages are not being
      // kept when they are.
      expect(state(MamRetention.never).keepsNothing, isTrue);
      for (final p in states.where((p) => p.policy != MamRetention.never)) {
        expect(p.keepsNothing, isFalse, reason: '$p');
      }
    });
  });

  // ---------------------------------------------------------------------
  group('`days: N` is a number, not a token', () {
    test('a cap is never part of the policy vocabulary', () {
      // The reason the number is a field and not an enum constant. If `days`
      // ever became a member, N would have to live in a string and be
      // re-parsed on every round trip, and the failure would be invisible
      // because the setting still looks set.
      for (final policy in MamRetention.values) {
        expect(
          int.tryParse(policy.token),
          isNull,
          reason: '${policy.token} is a token, not a number',
        );
        expect(
          policy.token,
          isNot(contains(RegExp(r'\d'))),
          reason: policy.token,
        );
      }
      expect(MamRetention.parse('30'), isNull);
      expect(MamRetention.parse('7'), isNull);
    });

    test('a cap survives the wire with its value intact', () {
      // The claim the module makes about itself, checked the only way it can
      // be: out through the element, back through the parser, same number. A
      // cap that silently became "for ever" or "for zero days" would leave a
      // user believing something the server was never told.
      for (final n in [1, 2, 7, 30, 365, 3650, 1000000]) {
        final wire = toPrefsElement(prefsWith(RetentionPolicy.days(n)));
        expect(
          wire.toXml(),
          contains("max='$n'"),
          reason: 'days $n: ${wire.toXml()}',
        );
        expect(
          parseMamPrefs(wire)!.defaultRetention!.maxDays,
          n,
          reason: 'days $n',
        );
      }
    });

    test('a cap and a policy survive together, not one or the other', () {
      // The two halves are independent. A form that could only carry one of
      // them would make "always, for 30 days" inexpressible and force the user
      // to choose which half to keep.
      for (final policy in MamRetention.values) {
        for (final n in [1, 30, 1000000]) {
          final original = state(policy, maxDays: n);
          final back = parseMamPrefs(toPrefsElement(prefsWith(original)))!;
          expect(
            back.defaultRetention,
            original,
            reason: '${policy.token} for $n days',
          );
        }
      }
    });

    test('an override keeps its own cap', () {
      // A cap on one conversation is the reason the number has to survive per
      // entry. Losing it there is worse than losing it on the account, because
      // the account default is at least visible somewhere else.
      final back = parseMamPrefs(
        toPrefsElement(
          prefsWith(
            state(MamRetention.roster, maxDays: 7),
            overrides: {juliet: state(MamRetention.always, maxDays: 365)},
          ),
        ),
      )!;
      expect(back.overrides[juliet], state(MamRetention.always, maxDays: 365));
      expect(back.defaultRetention, state(MamRetention.roster, maxDays: 7));
    });

    test('a cap with no policy is a real, distinguishable state', () {
      // `RetentionPolicy.days(30)` is the honest answer to a `<prefs max='30'/>`,
      // and pairing it with a guessed policy is how a server that answered one
      // question gets recorded as having answered two.
      final capWithoutPolicy = RetentionPolicy.days(30);
      expect(capWithoutPolicy.policy, isNull);
      expect(capWithoutPolicy.unrecognised, isNull);
      expect(capWithoutPolicy.maxDays, 30);
      expect(capWithoutPolicy, isNot(state(MamRetention.roster, maxDays: 30)));
      expect(privacySummary(prefsWith(capWithoutPolicy)), contains('30 days'));
    });

    test('a cap of zero or less is refused rather than chosen between', () {
      // Two opposite privacy postures are available for zero — keep nothing, or
      // keep for a day — and silently picking one is the whole failure this
      // file is about. Throwing is what forces the caller to decide.
      for (final bad in [0, -1, -30]) {
        expect(
          () => RetentionPolicy.days(bad),
          throwsA(isA<ArgumentError>()),
          reason: 'days($bad)',
        );
        expect(
          () => RetentionPolicy(maxDays: bad, policy: MamRetention.always),
          throwsA(isA<ArgumentError>()),
          reason: 'maxDays: $bad',
        );
      }
    });

    test('a cap of one day is allowed, and reads as one day', () {
      // The boundary the previous test pushes against. If 1 were refused then
      // "keep for exactly one day" would be inexpressible and the shortest
      // useful retention would be unreachable.
      expect(RetentionPolicy.days(1).maxDays, 1);
      final summary = privacySummary(
        prefsWith(state(MamRetention.always, maxDays: 1)),
      );
      expect(summary, contains('1 day'));
      expect(
        summary,
        isNot(contains('1 days')),
        reason: '"1 days" reads as a bug and undermines the number',
      );
    });

    test('a policy and an unreadable token cannot both be set', () {
      // "The server said what, in words we do not have" and "the server said
      // which messages" are mutually exclusive readings. A constructor that
      // accepted both would let a caller assert a policy it never read.
      expect(
        () =>
            RetentionPolicy(policy: MamRetention.never, unrecognised: 'weird'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the exposure ordering is the order the enum claims', () {
      // The doc comment calls the ordering "the point" and promises
      // never < onlyMuc < roster < always < unlimited. If the exposures stopped
      // being monotone, a shortening would be ranked by how the wire happens to
      // spell two policies.
      expect(MamRetention.values.map((p) => p.name), [
        'never',
        'onlyMuc',
        'roster',
        'always',
        'unlimited',
      ]);
      for (var i = 1; i < MamRetention.values.length; i++) {
        expect(
          MamRetention.values[i].exposure,
          greaterThan(MamRetention.values[i - 1].exposure),
          reason:
              '${MamRetention.values[i].name} must outrank '
              '${MamRetention.values[i - 1].name}',
        );
      }
    });

    test('every policy survives its own token, and no two share one', () {
      // A round trip through a token is how the connection layer keeps these
      // between runs. Two policies collapsing onto one token would make a
      // restored setting a different one from the one the user chose.
      for (final policy in MamRetention.values) {
        expect(MamRetention.parse(policy.token), policy, reason: policy.token);
      }
      final wire = MamRetention.values.map((p) => p.token).toList();
      expect(wire.toSet(), hasLength(wire.length));
    });
  });

  // ---------------------------------------------------------------------
  group('the summary a user reads', () {
    test('no policy produces an empty or whitespace-only sentence', () {
      // A control whose effect cannot be described is not a control. Swept over
      // the whole space and both summary functions, because the sentence is
      // built in four separate branches and each is a place an early return
      // could fall out of.
      for (final p in states) {
        for (final summary in [
          privacySummary(prefsWith(p)),
          conversationPrivacySummary(prefsWith(p), juliet),
          privacySummary(prefsWith(null, overrides: {juliet: p})),
          conversationPrivacySummary(
            prefsWith(state(MamRetention.roster), overrides: {juliet: p}),
            juliet,
          ),
        ]) {
          expect(summary.trim(), isNotEmpty, reason: '$p');
          expect(
            summary.trim(),
            summary,
            reason: '$p: leading or trailing space',
          );
        }
      }
    });

    test('and every one of them names the period, or says it is unknown', () {
      // "Name the period, always" is the rule that stops a sentence reading as
      // "indefinitely" when the server said nothing at all. Asserted over every
      // state and both summaries, so the guarantee holds by construction
      // rather than by the four branches happening to cooperate today.
      //
      // The one exception is a policy that keeps nothing, whose branch
      // deliberately names no period; the second assertion below pins that as
      // the *only* exception rather than leaving it to chance. See the report:
      // the doc's "always" and its `never` branch contradict each other, and
      // the code is right.
      for (final p in states.where((p) => p.policy != MamRetention.never)) {
        for (final summary in [
          privacySummary(prefsWith(p)),
          conversationPrivacySummary(prefsWith(p), juliet),
        ]) {
          expect(
            RegExp(r'\d+ days?|1 day|no limit|not said|unknown|when it will')
                .hasMatch(summary),
            isTrue,
            reason: '$p summarised as "$summary"',
          );
        }
      }
      for (final cap in dayCaps) {
        expect(
          privacySummary(prefsWith(state(MamRetention.never, maxDays: cap))),
          isNot(contains('${cap ?? 0} days')),
          reason: 'a cap on `never` is not a period; nothing is kept',
        );
      }
    });

    test('an unstated period is stated as unstated, not left blank', () {
      // The wording required for the three policies that archive something and
      // are not `unlimited` (`never` has its own case below): an absent cap is a
      // silence, and a silence reads as "indefinitely".
      for (final policy in [
        MamRetention.onlyMuc,
        MamRetention.roster,
        MamRetention.always,
      ]) {
        expect(
          privacySummary(prefsWith(state(policy))),
          contains('has not said when it will delete them'),
          reason: '${policy.token} with no cap',
        );
      }
    });

    test('`unlimited` is the one policy whose token is a period', () {
      // For `unlimited` an absent cap *is* an answer, so it gets its own
      // clause. This is the one place the module is allowed to describe an
      // unbounded period, and it must not leak to the other four.
      expect(
        privacySummary(prefsWith(state(MamRetention.unlimited))),
        contains('with no limit on how long'),
      );
      for (final p in states.where((p) => p.policy != MamRetention.unlimited)) {
        expect(
          privacySummary(prefsWith(p)),
          isNot(contains('with no limit on how long')),
          reason: '$p must not claim an unbounded period',
        );
      }
    });

    test('`never` names nothing because it keeps nothing', () {
      // The one branch allowed to skip the period. A cap on a policy that keeps
      // nothing is meaningless, and naming one would read as a promise about
      // something that is not kept.
      expect(
        privacySummary(prefsWith(state(MamRetention.never))),
        'The server has been told to keep none of your messages.',
      );
      expect(
        conversationPrivacySummary(
          prefsWith(state(MamRetention.never)),
          juliet,
        ),
        'In this conversation, as everywhere else, the server has been told to '
        'keep none of your messages.',
      );
    });

    test('a cap alongside `unlimited` is kept, not reconciled away', () {
      // The two may well be redundant rather than contradictory ("unlimited"
      // about volume, `max` about age). Assuming no cap is the one reading
      // under which a user who set a limit is told they have none.
      final summary = privacySummary(
        prefsWith(state(MamRetention.unlimited, maxDays: 30)),
      );
      expect(summary, contains('30 days'));
      expect(summary, isNot(contains('no limit')));
    });

    test('an unrecognised token is quoted and the period called unknown', () {
      // Actionable: the user has to be able to read the thing that was not
      // understood and go and ask about it. A paraphrase is not actionable.
      final summary = privacySummary(
        prefsWith(state(null, unrecognised: 'weird')),
      );
      expect(summary, contains('"weird"'));
      expect(summary, contains('unknown'));
      expect(summary, contains('for how long'));
    });

    test('every claim in a summary is attributed to the server', () {
      // The subject of every sentence is what the server was *told*, or what it
      // said, or what it did not say. A sentence that stated a fact about the
      // server's storage in the client's own voice would be claiming an
      // outcome nobody has confirmed.
      for (final p in states) {
        final summary = privacySummary(prefsWith(p));
        expect(
          RegExp(
            r'has been told to keep|has said|has not said|does not understand',
          ).hasMatch(summary),
          isTrue,
          reason: '$p states an unattributed fact: "$summary"',
        );
        expect(
          RegExp(r'\bis keeping\b|\bwill keep\b|\bkeeps your\b')
              .hasMatch(summary),
          isFalse,
          reason: '$p claims an outcome: "$summary"',
        );
      }
    });

    test('the caveat is present and says the protocol does not delete', () {
      // The line under every summary, and the reason a retention setting is not
      // a deletion. If this ever softens to "may not delete", a screen showing
      // it becomes a promise the protocol cannot keep.
      expect(mamPrefsCaveat, isNotEmpty);
      expect(mamPrefsCaveat, contains('already'));
      expect(mamPrefsCaveat, contains('does not delete'));
    });

    test('the conversation summary says when the answer is the default', () {
      // "The server has been told to keep nothing" and "…and not here either"
      // are different facts, and the second is the one a user standing in that
      // conversation is asking about.
      final summary = conversationPrivacySummary(
        prefsWith(state(MamRetention.never)),
        juliet,
      );
      expect(summary, contains('as everywhere else'));
      expect(summary, contains('In this conversation'));
    });

    test('and does not say so when there is an override', () {
      // The other half. If "as everywhere else" appeared on a screen showing a
      // per-conversation policy, the user would be told the wrong thing about
      // the conversation in front of them.
      final summary = conversationPrivacySummary(
        prefsWith(
          state(MamRetention.always),
          overrides: {juliet: state(MamRetention.never)},
        ),
        juliet,
      );
      expect(summary, isNot(contains('as everywhere else')));
      expect(summary, contains('none of your messages'));
    });

    test('FINDING: a summary always says which answer it is reporting', () {
      // FINDING — kept failing rather than weakened.
      //
      // What the doc claims, for `conversationPrivacySummary`: "Says so when
      // the answer comes from the account default, because 'the server has been
      // told to keep nothing' and 'the server has been told to keep nothing,
      // and not here either' are different facts and the second one is the one
      // a user in that conversation is asking about." Stated twice: once for
      // the override case ("In this conversation, …") and once for the default
      // case ("… as everywhere else, …").
      //
      // What the code does: `_summarise` drops its `subject` argument in two of
      // its four branches — a null policy (with or without a cap) and an
      // unrecognised token — which is three of the five shapes a policy can
      // take. So for those the conversation summary is byte-identical to the
      // account summary, and a user who opened a conversation to ask "what does
      // this one keep" is shown the account-wide sentence with nothing saying it
      // is the account-wide sentence. In the override direction the same drop
      // means the "In this conversation" clause never appears, so a
      // per-conversation policy of "keeps some of your messages for 30 days"
      // reads exactly like the account default's sentence.
      //
      // Which is right: the code should carry the subject through. The whole
      // reason the function exists is to answer a question about one
      // conversation, and in these states it answers a question about the
      // account without saying so. The sentences are not *wrong* — they
      // describe the policy that does apply — but the sentence the user came
      // for is the one that cannot distinguish the two cases, and "the server
      // has been told to keep nothing" from an account default is precisely the
      // distinction the doc says a user in that conversation needs.
      // Both directions in one list, so one failure reports all of them rather
      // than only whichever was asserted first.
      final unattributed = <String>[
        for (final p in noReadablePolicy)
          if (!conversationPrivacySummary(
            prefsWith(state(MamRetention.unlimited), overrides: {juliet: p}),
            juliet,
          ).contains('In this conversation'))
            'as an override: $p',
        for (final p in noReadablePolicy)
          if (conversationPrivacySummary(prefsWith(p), juliet) ==
              privacySummary(prefsWith(p)))
            'as the account default: $p',
      ];
      expect(
        unattributed,
        isEmpty,
        reason: 'a summary that does not say which answer it is reporting',
      );
    });

    test('every policy produces a sentence no other policy produces', () {
      // If two policies produced the same sentence, a user could not tell which
      // one they had chosen, and a support answer quoting the sentence would be
      // quoting something that does not identify the setting. `always` and
      // `unlimited` share a noun phrase on purpose, and the period clause is
      // what tells them apart — so this also pins that the period clause
      // really is load-bearing.
      final sentences = <String, MamRetention>{};
      for (final policy in MamRetention.values) {
        final sentence = privacySummary(prefsWith(state(policy)));
        final clash = sentences[sentence];
        expect(
          clash,
          isNull,
          reason: '$policy and $clash both read "$sentence"',
        );
        sentences[sentence] = policy;
      }
    });

    test('every sentence is a sentence and nothing hedges', () {
      // A sentence the user cannot decide from is decoration, and the decision
      // is theirs. Hedging is banned for the same reason: "may" and "might"
      // are not a posture. The interpolated token is excluded from the ban
      // because it is the server's word, quoted verbatim on purpose.
      for (final p in states) {
        for (final summary in [
          privacySummary(prefsWith(p)),
          conversationPrivacySummary(prefsWith(p), juliet),
        ]) {
          expect(summary.endsWith('.'), isTrue, reason: '$p: "$summary"');
          expect(summary.endsWith(' '), isFalse, reason: '$p: "$summary"');
          if (p.unrecognised == null) {
            expect(
              RegExp(r'\bmay\b|\bmight\b|\bperhaps\b|\bpossibly\b')
                  .hasMatch(summary),
              isFalse,
              reason: '$p hedges: "$summary"',
            );
          }
        }
      }
    });

    test('no sentence claims a deletion', () {
      // Nothing in this protocol removes anything, so no sentence here may say
      // something is gone. The one legitimate mention of deleting is the
      // clause that reports the server failed to say *when* it would, so a
      // mention of it anywhere else is a promise the code cannot keep.
      for (final p in states.where((p) => p.unrecognised == null)) {
        for (final summary in [
          privacySummary(prefsWith(p)),
          conversationPrivacySummary(prefsWith(p), juliet),
        ]) {
          if (summary.contains('delete')) {
            expect(
              summary,
              contains('has not said when it will delete them'),
              reason: '$p mentions deleting: "$summary"',
            );
          }
          expect(
            RegExp(r'\bdeleted\b|\bremoved\b|\berased\b|\bgone\b|\bpurged\b')
                .hasMatch(summary),
            isFalse,
            reason: '$p claims something was disposed of: "$summary"',
          );
        }
      }
    });
  });

  // ---------------------------------------------------------------------
  group('precedence: the override beats the account default', () {
    test('an override wins even when it is the more restrictive of the two', () {
      // The case the module's own doc calls out by name. An account default of
      // `always` must not quietly re-archive the one person the user switched
      // archiving off for, because a rule that lets the global setting win is
      // exactly what makes that impossible.
      final prefs = prefsWith(
        state(MamRetention.always),
        overrides: {juliet: state(MamRetention.never)},
      );
      expect(
        effectiveRetention(prefs: prefs, conversation: juliet),
        state(MamRetention.never),
      );
      expect(privacySummary(prefs), contains('a copy of all your messages'));
      expect(
        conversationPrivacySummary(prefs, juliet),
        contains('none of your messages'),
      );
    });

    test('and an override wins when it is the more permissive of the two', () {
      // The reverse, which is the one a hand-written table forgets. "This one
      // conversation is exempt" is not a special case of the rule; it is the
      // rule.
      final prefs = prefsWith(
        state(MamRetention.never),
        overrides: {juliet: state(MamRetention.always)},
      );
      expect(
        effectiveRetention(prefs: prefs, conversation: juliet),
        state(MamRetention.always),
      );
      expect(privacySummary(prefs), contains('none of your messages'));
      expect(
        conversationPrivacySummary(prefs, juliet),
        contains('a copy of all your messages'),
      );
    });

    test('precedence holds for every pair of policies', () {
      // Swept, because a rule that preferred the *more restrictive* of the two
      // would pass both hand-written cases above — the override would lose in
      // one direction each time — while being wrong in every other pair.
      for (final account in policies) {
        for (final local in policies) {
          if (local == null) continue;
          final prefs = prefsWith(
            account == null ? null : state(account),
            overrides: {juliet: state(local)},
          );
          expect(
            effectiveRetention(prefs: prefs, conversation: juliet),
            state(local),
            reason:
                'account ${account?.token ?? 'unstated'} vs override $local',
          );
        }
      }
    });

    test(
      'an override is keyed on the bare JID, whichever resource is asked',
      () {
        // An override filed against `juliet@…/phone` must be found by a lookup
        // for `juliet@…`, or a resource-qualified lookup would miss it and hand
        // the conversation back to the account default — re-enabling archiving
        // for exactly the person the user switched it off for.
        final policy = state(MamRetention.never);
        for (final filed in [juliet, julietPhone, julietTablet]) {
          final prefs = prefsWith(null, overrides: {filed: policy});
          for (final asked in [juliet, julietPhone, julietTablet]) {
            expect(
              prefs.overrideFor(asked),
              policy,
              reason: 'filed $filed, asked $asked',
            );
            expect(
              effectiveRetention(prefs: prefs, conversation: asked),
              policy,
              reason: 'filed $filed, asked $asked',
            );
          }
        }
      },
    );

    test('two entries for one person collapse to one, keyed on the bare JID', () {
      // Two policies for one person is a server-side detail the user has no way
      // to see. Last one read wins and only one is kept; the alternative is two
      // rows and a question of which the server applied.
      final prefs = prefsWith(
        null,
        overrides: {
          julietPhone: state(MamRetention.always),
          julietTablet: state(MamRetention.never),
        },
      );
      expect(prefs.overrides.keys.toSet(), {juliet});
      expect(prefs.overrideFor(julietPhone), state(MamRetention.never));
      expect(prefs.overrideFor(julietTablet), state(MamRetention.never));
    });

    test('an override for a JID we cannot parse is still kept', () {
      // Dropping an override because the JID looked odd is the documented
      // failure: it hands that conversation back to the account default, which
      // is the permissive direction.
      for (final odd in ['@example.org', 'no-at-sign', 'a/b/c', '/orphan']) {
        final prefs = prefsWith(
          state(MamRetention.always),
          overrides: {odd: state(MamRetention.never)},
        );
        expect(
          effectiveRetention(prefs: prefs, conversation: odd),
          state(MamRetention.never),
          reason: 'JID "$odd" must not lose its override',
        );
      }
    });

    test('no override and no default is null, not the permissive reading', () {
      // The honest answer: the server applies a policy of its own that it did
      // not tell us, which is not the same as a permissive one.
      expect(
        effectiveRetention(prefs: MamPrefs(), conversation: juliet),
        isNull,
      );
      expect(
        effectiveRetention(prefs: prefsWith(null), conversation: juliet),
        isNull,
      );
    });

    test('withOverride and withDefault replace exactly one thing', () {
      // A mutator that dropped the resource, or another conversation's
      // override, would be an unreviewed change made on the user's behalf,
      // which the module names as the one way it could cause the harm it exists
      // to prevent.
      final base = MamPrefs(
        resource: 'me@capulet.lit/phone',
        defaultRetention: state(MamRetention.roster),
        overrides: {juliet: state(MamRetention.never)},
      );
      final widened = base.withDefault(state(MamRetention.always));
      expect(widened.defaultRetention, state(MamRetention.always));
      expect(widened.overrides, base.overrides);
      expect(widened.resource, base.resource);

      final removed = base.withOverride(juliet, null);
      expect(removed.overrideFor(juliet), isNull);
      expect(removed.overrides, isEmpty);
      expect(removed.defaultRetention, base.defaultRetention);
      expect(removed.resource, base.resource);

      final replaced = base.withOverride(
        'tybalt@capulet.lit',
        state(MamRetention.roster, maxDays: 7),
      );
      expect(
        replaced.overrideFor('tybalt@capulet.lit'),
        state(MamRetention.roster, maxDays: 7),
      );
      expect(replaced.overrideFor(juliet), state(MamRetention.never));
      expect(
        base.overrideFor('tybalt@capulet.lit'),
        isNull,
        reason: 'the original must not be mutated',
      );
    });

    test('withOverride removes by bare JID whichever form is passed', () {
      // Removing is a change like any other, and it is one that usually
      // *increases* what the server keeps. A removal that missed because the
      // caller used a different resource would leave the override in place.
      final base = prefsWith(
        null,
        overrides: {julietPhone: state(MamRetention.never)},
      );
      for (final form in [juliet, julietPhone, julietTablet]) {
        expect(
          base.withOverride(form, null).overrideFor(juliet),
          isNull,
          reason: 'removed via $form',
        );
      }
    });
  });

  // ---------------------------------------------------------------------
  group('a server that did not answer is unknown, not a policy', () {
    test('an unreadable discovery answer is unknown, never supported', () {
      // The failure `resolveTrack` guards against with `unknownPeers` and
      // `capabilities.dart` with `reliable: false`, in the one place where the
      // wrong answer is permissive. A slow network must not tell a user their
      // server has no archive control, and must not hand back a `set` whose
      // effect nobody has confirmed. Swept over the answers and the var.
      for (final features in <List<String>>[
        [],
        [MamPrefsForm.feature],
        ['urn:xmpp:mam:2'],
        [MamPrefsForm.feature, 'urn:xmpp:mam:2'],
        ['urn:xmpp:mam:0'],
      ]) {
        expect(
          supportFromFeatures(features, featuresReadable: false),
          MamPrefsSupport.unknown,
          reason: 'unreadable, features $features',
        );
        expect(
          serverSupportsMamPrefs(
            supportFromFeatures(features, featuresReadable: false),
          ),
          isFalse,
          reason: 'an unreadable answer is not a permission: $features',
        );
      }
    });

    test('an empty but readable list is unsupported, not unknown', () {
      // The opposite direction. "We asked and it is not there" is a real answer
      // and the user deserves it; collapsing it into `unknown` would mean asking
      // again forever and never telling the user the truth.
      expect(
        supportFromFeatures(const [], featuresReadable: true),
        MamPrefsSupport.unsupported,
      );
      expect(
        supportFromFeatures(['urn:xmpp:mam:2'], featuresReadable: true),
        MamPrefsSupport.unsupported,
        reason: 'a MAM query var is the opposite privacy direction',
      );
      expect(
        supportFromFeatures(['urn:xmpp:mam:0'], featuresReadable: true),
        MamPrefsSupport.unsupported,
      );
    });

    test('the advertised var is the preferences namespace', () {
      // Deliberately not `urn:xmpp:mam:2`: a server advertising MAM queries is
      // telling us it keeps an archive, which must never be read as "and there
      // is a setting for it".
      expect(MamPrefsForm.feature, MamPrefsForm.namespace);
      expect(MamPrefsForm.feature, isNot('urn:xmpp:mam:2'));
      expect(
        supportFromFeatures([MamPrefsForm.feature], featuresReadable: true),
        MamPrefsSupport.supported,
      );
    });

    test('only `supported` says a set should be expected to work', () {
      // `unknown` and `unsupported` fail differently, but neither of them is a
      // permission, which is the only thing this getter is asked.
      for (final support in MamPrefsSupport.values) {
        expect(
          support.honoured,
          support == MamPrefsSupport.supported,
          reason: '$support',
        );
        expect(
          serverSupportsMamPrefs(support),
          support.honoured,
          reason: '$support',
        );
      }
    });

    test('a `set` needs both a supporting server and something read first', () {
      // Two independent reasons to say no, neither of which is "send it and
      // see". The set form *replaces*, so a set built from a picture we never
      // read erases the overrides we never saw: an unreviewed change made on
      // the user's behalf, made worse because it looks like a privacy
      // improvement.
      for (final support in MamPrefsSupport.values) {
        for (final current in <MamPrefs?>[
          null,
          MamPrefs(),
          prefsWith(state(MamRetention.never)),
        ]) {
          expect(
            mayWritePreferences(support: support, current: current),
            support == MamPrefsSupport.supported && current != null,
            reason:
                'support $support, current ${current == null ? 'unread' : 'read'}',
          );
        }
      }
    });

    test('a picture that said nothing is still a picture', () {
      // `MamPrefs()` is an answer from the server: no default was stated.
      // Refusing to write over it would leave the user unable to set a
      // preference on any server that starts from a blank form, which is the
      // state a fresh account is in.
      expect(
        mayWritePreferences(
          support: MamPrefsSupport.supported,
          current: MamPrefs(),
        ),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------
  group('resource scoping', () {
    test('an unscoped answer describes the account, for every resource', () {
      // Null here means nobody scoped this, which is a statement about the
      // whole account and so is true on every resource's page.
      final prefs = prefsWith(state(MamRetention.never));
      expect(prefs.resource, isNull);
      for (final resource in [null, 'phone', 'tablet', 'desktop']) {
        expect(appliesToResource(prefs, resource), isTrue, reason: '$resource');
      }
    });

    test('a scoped answer does not describe another resource', () {
      // The harm named in the doc: showing a phone-scoped answer on the
      // tablet's page reports one device's privacy posture as another's, and
      // the user has no way to notice.
      final scoped = MamPrefs(
        resource: 'phone',
        defaultRetention: state(MamRetention.never),
      );
      expect(appliesToResource(scoped, 'phone'), isTrue);
      expect(appliesToResource(scoped, 'tablet'), isFalse);
      expect(appliesToResource(scoped, 'desktop'), isFalse);
    });

    test('FINDING: nor the account it was never scoped to', () {
      // FINDING — kept failing rather than weakened.
      //
      // What the doc claims: "A preferences answer is about one archive. Showing
      // a resource-scoped answer on another resource's page would report one
      // device's privacy posture as another's, and the user has no way to
      // notice." And, justifying the first clause: "One scoped to another
      // resource describes neither this one nor the account."
      //
      // What the code does: `scoped == null || resource == null || scoped ==
      // resource`. The middle clause is the one with no justification in the
      // comment above it, and it makes the sentence false: with no resource
      // named, the only thing the answer could describe is the account, and a
      // phone-scoped answer does not describe it. `resource: null` on the
      // *answer* is already documented as "we did not ask about a resource, or
      // the answer named none" — not "this is everybody's answer" — so the
      // argument for the clause does not exist on that side either.
      //
      // Which is right: the code is wrong. The account-wide privacy page is
      // exactly where a phone-scoped answer must not appear, and the clause
      // lets it appear there precisely when the caller has not said which
      // resource it is showing — the case where the caller is showing the
      // account.
      final leaked = <String>[
        for (final scope in ['phone', 'tablet', 'desktop'])
          if (appliesToResource(MamPrefs(resource: scope), null)) scope,
      ];
      expect(
        leaked,
        isEmpty,
        reason: 'a resource-scoped answer offered as the account-wide picture',
      );
    });

    test('nothing we have read applies to nothing', () {
      // "We have not asked" is not a picture. `resolveTrack` insists the fact
      // be about the thing being acted on; so does this.
      expect(appliesToResource(null, 'phone'), isFalse);
      expect(appliesToResource(null, null), isFalse);
    });

    test(
      'the resource survives a parse, from the argument or the attribute',
      () {
        // The IQ's `to` is authoritative and the element's own `to` is a
        // fallback for a server that names it there.
        final element = toPrefsElement(
          MamPrefs(
            resource: 'phone',
            defaultRetention: state(MamRetention.never),
          ),
        );
        expect(parseMamPrefs(element, resource: 'tablet')!.resource, 'tablet');
        expect(parseMamPrefs(element)!.resource, 'phone');
        expect(
          parseMamPrefs(toPrefsElement(prefsWith(state(MamRetention.never))))!
              .resource,
          isNull,
        );
      },
    );
  });

  // ---------------------------------------------------------------------
  group('shortening retention warns, lengthening it does not', () {
    test('shortening warns and lengthening does not, for the named policies', () {
      // The asymmetry the whole module is built around. A user who shortens
      // retention must be told, before they do it, that this does not delete
      // what the server has. A user who lengthens it must not be shown a dialog
      // they will learn to dismiss — and if both warned, the dismissal is what
      // generalises, and it takes the important one with it.
      final descending = [
        ['unlimited', 'always'],
        ['always', 'roster'],
        ['roster', 'only-muc'],
        ['only-muc', 'never'],
      ];
      for (final pair in descending) {
        expectShorterWarning(
          warningsBeforeChange(
            current: state(MamRetention.parse(pair[0])!),
            next: state(MamRetention.parse(pair[1])!),
            support: MamPrefsSupport.supported,
          ),
          'shortening ${pair[0]} → ${pair[1]} must warn',
        );
      }
      for (final pair in descending.reversed) {
        expectNoShorterWarning(
          warningsBeforeChange(
            current: state(MamRetention.parse(pair[1])!),
            next: state(MamRetention.parse(pair[0])!),
            support: MamPrefsSupport.supported,
          ),
          'lengthening ${pair[0]} → ${pair[1]} must stay quiet',
        );
      }
    });

    test('the direction is decided by exposure, not by the token spelling', () {
      // A rule keyed on the wire token rather than on the ranking would get
      // `onlyMuc` → `never` wrong, and get it right only for pairs that happen
      // to be adjacent in the file.
      for (final from in MamRetention.values) {
        for (final to in MamRetention.values) {
          final warnings = warningsBeforeChange(
            current: state(from),
            next: state(to),
            support: MamPrefsSupport.supported,
          );
          expect(
            warnings.any((w) => w.kind == MamChangeKind.shorterRetention),
            to.exposure < from.exposure,
            reason: '${from.token} → ${to.token}',
          );
        }
      }
    });

    test('an unknown current is never described as a change in either way', () {
      // "We do not know what the server is already keeping" and then saying
      // "this is a decrease" in the same breath is the module doing exactly
      // what it exists to refuse: reading an absence of evidence as a fact.
      // Swept over every next state and every support value.
      for (final next in states) {
        for (final support in MamPrefsSupport.values) {
          final warnings = warningsBeforeChange(
            current: null,
            next: next,
            support: support,
          );
          expectNoShorterWarning(warnings, 'unknown → $next on $support');
          expect(
            warnings.map((w) => w.kind),
            contains(MamChangeKind.unknownCurrent),
            reason: 'unknown → $next on $support',
          );
        }
      }
    });

    test('FINDING: an unrankable pair is not called a shortening either', () {
      // FINDING — kept failing rather than weakened.
      //
      // What the doc claims: "False whenever the two cannot be ranked against
      // each other — not because they compare equal, but because 'we cannot
      // tell' is not evidence of a reduction." And, of the cap comparison: an
      // absent cap "has not told us it keeps things for longer, it has told us
      // less, and that case is warned about separately rather than being
      // counted as a lengthening."
      //
      // What the code does: when both sides state no policy at all it falls
      // through to `_isShorterCap`, which reads a missing cap as unbounded — so
      // a `current` that carries *no readable information at all* is ranked
      // against a stated cap and the change is called a shortening. Those
      // currents are reachable from a real stanza: `<prefs/>` and
      // `<prefs max='soon'/>` both parse to a `RetentionPolicy` with every
      // field null, and `<prefs default='weird'/>` parses to one with an
      // unreadable token. The code's own justification for the fall-through is
      // "two cap-only policies compare fine, on their caps", and an empty
      // policy and an unrecognised token are not cap-only policies — there is
      // nothing to compare, and their own summaries say so.
      //
      // Which is right: the code should stop. Note this is the opposite
      // direction from the `never` finding below and the two are compatible: a
      // cap-only state states a real period, so `never` can be ranked against
      // it; an empty or unrecognised state states nothing at all, so it cannot
      // be ranked against anything. The pairs whose `next` is `never` are
      // excluded here precisely because that case is claimed to be a
      // shortening, not an unrankable pair.
      final unrankedButCalledShortening = <String>[];
      for (final pair in everyPair()) {
        final current = pair[0];
        final next = pair[1];
        if (current.exposure != null && next.exposure != null) continue;
        // Cap-only → `never` is a real shortening (see the FINDING below); skip
        // every never next so this sweep stays about unrankable pairs only.
        if (next.policy == MamRetention.never) continue;
        // Two cap-only policies *are* rankable, on their caps — see
        // "two cap-only states still compare". An empty or unrecognised
        // current is what this FINDING is about.
        final currentCapOnly =
            current.policy == null &&
            current.unrecognised == null &&
            current.maxDays != null;
        final nextCapOnly =
            next.policy == null &&
            next.unrecognised == null &&
            next.maxDays != null;
        if (currentCapOnly && nextCapOnly) continue;
        if (shortensRetention(current, next)) {
          unrankedButCalledShortening.add('$current → $next');
        }
      }
      expect(
        unrankedButCalledShortening,
        isEmpty,
        reason: 'a direction claimed for a pair that cannot be ranked',
      );
    });

    test('FINDING: a current we cannot describe is reported as unknown', () {
      // FINDING — kept failing rather than weakened. The same root cause as
      // the test above, named rather than swept.
      //
      // `MamChangeKind.unknownCurrent` exists for "We do not know what the
      // server is keeping now, so the direction of the change cannot be stated
      // in either direction", and `MamPrefs.defaultRetention` already says that
      // even a *null* default means "the server is applying a policy of its own
      // that it did not tell us". A state that is present but unreadable is the
      // same epistemic position with one fewer step of inference — and
      // `warningsBeforeChange` only tests `current == null`, the pointer, so
      // these states fall through to a direction claim.
      for (final unreadable in states.where(
        (p) => !carriesSomething(p) || p.unrecognised != null,
      )) {
        for (final next in states) {
          final warnings = warningsBeforeChange(
            current: unreadable,
            next: next,
            support: MamPrefsSupport.supported,
          );
          expect(
            warnings.map((w) => w.kind),
            contains(MamChangeKind.unknownCurrent),
            reason: '$unreadable → $next: the direction cannot be stated',
          );
        }
      }
    });

    test('a shorter cap on the same policy is a shortening', () {
      // The other half of "which and for how long": lowering the day count
      // while keeping the same policy does reduce what the server holds, and
      // the user is owed the same warning they get for moving a rung down the
      // ladder. A rule that only compared exposures would miss this entirely.
      for (final from in [3650, 365, 30]) {
        for (final to in [1, 7, 30, 365]) {
          expect(
            shortensRetention(
              state(MamRetention.always, maxDays: from),
              state(MamRetention.always, maxDays: to),
            ),
            to < from,
            reason: '$from → $to days on always',
          );
        }
      }
    });

    test('a longer cap on the same policy is not', () {
      for (final from in [1, 7, 30]) {
        for (final to in [365, 3650, 1000000]) {
          expect(
            shortensRetention(
              state(MamRetention.always, maxDays: from),
              state(MamRetention.always, maxDays: to),
            ),
            isFalse,
            reason: '$from → $to days on always',
          );
        }
      }
    });

    test('a cap stated where there was none counts as a shortening', () {
      // `_isShorterCap`'s body argues that an absent cap is unbounded, which
      // makes a newly stated cap the smaller of the two. That is a deliberate
      // reading and it is the right one — the user typing a number is reducing
      // what the server holds — but the one-line summary of the same function
      // says the opposite ("a cap where there was none does not"). Asserted so
      // the behaviour is on the record; see the report.
      final current = state(MamRetention.always);
      final next = state(MamRetention.always, maxDays: 30);
      expect(current.maxDays, isNull);
      expectShorterWarning(
        warningsBeforeChange(
          current: current,
          next: next,
          support: MamPrefsSupport.supported,
        ),
        'stating a cap where there was none',
      );
    });

    test('a cap being dropped claims nothing in either direction', () {
      // The mirror. We lose the number, so we know nothing about the direction,
      // and the uncertainty is carried by the summary of the new state rather
      // than by a direction claim here.
      expect(
        shortensRetention(
          state(MamRetention.always, maxDays: 30),
          state(MamRetention.always),
        ),
        isFalse,
      );
      expectNoShorterWarning(
        warningsBeforeChange(
          current: state(MamRetention.always, maxDays: 30),
          next: state(MamRetention.always),
          support: MamPrefsSupport.supported,
        ),
        'dropping a cap',
      );
    });

    test('two states that keep nothing cannot shorten into each other', () {
      // Nothing is kept either way, so a "shorter" warning here would be a
      // privacy dialog on a change that cannot affect privacy at all — and
      // warnings that fire on harmless changes are warnings the user learns to
      // dismiss.
      for (final from in neverVariants) {
        for (final to in neverVariants) {
          expect(shortensRetention(from, to), isFalse, reason: '$from → $to');
          expectNoShorterWarning(
            warningsBeforeChange(
              current: from,
              next: to,
              support: MamPrefsSupport.supported,
            ),
            '$from → $to',
          );
        }
      }
    });

    test('nothing warns about a change that was not made', () {
      // The re-submission case. A page that warns about every save trains the
      // user to tap through the one that matters, and the user in question is
      // the one shortening retention because they are worried.
      for (final p in states) {
        expectNoShorterWarning(
          warningsBeforeChange(
            current: p,
            next: p,
            support: MamPrefsSupport.supported,
          ),
          '$p → itself',
        );
      }
    });

    test('a shortening that also cannot be confirmed keeps both warnings', () {
      // "A list, not a single warning: one change can be shorter *and*
      // unverifiable, and a function that returned only one of them would have
      // thrown the other away." A dialog about a shortening on a server that
      // will not honour it is still the truth, and the unverifiable half is the
      // half the user needs in order to decide.
      final warnings = warningsBeforeChange(
        current: state(MamRetention.unlimited),
        next: state(MamRetention.never),
        support: MamPrefsSupport.unsupported,
      );
      expect(
        warnings.map((w) => w.kind),
        containsAll(<MamChangeKind>[
          MamChangeKind.shorterRetention,
          MamChangeKind.mayNotTakeEffect,
        ]),
      );
      // Most consequential first, as documented.
      expect(warnings.first.kind, MamChangeKind.shorterRetention);
    });

    test(
      'a supported server produces at most one warning, about the direction',
      () {
        // With nothing unverifiable, there is nothing to say but what happened
        // to the retention. A second warning here would be noise over the
        // sentence the user has to read.
        for (final current in <RetentionPolicy?>[null, ...states]) {
          for (final next in states) {
            final warnings = warningsBeforeChange(
              current: current,
              next: next,
              support: MamPrefsSupport.supported,
            );
            expect(
              warnings.length,
              lessThanOrEqualTo(1),
              reason: '$current → $next on a supported server',
            );
          }
        }
      },
    );

    test('an unsupported server warns but an unknown one only reports', () {
      // The two failure modes are different and the user needs to know which:
      // for one there is no setting to change, for the other there may be one
      // waiting on a better connection. And only the first may demand a
      // confirmation — a dialog that blocks every edit while the server is
      // quiet trains dismissal of the one above it, the one that matters.
      final unsupported = MamChangeWarning.mayNotTakeEffect(
        MamPrefsSupport.unsupported,
      );
      final unknown = MamChangeWarning.mayNotTakeEffect(
        MamPrefsSupport.unknown,
      );
      expect(unsupported.kind, MamChangeKind.mayNotTakeEffect);
      expect(unknown.kind, MamChangeKind.mayNotTakeEffect);
      expect(unsupported.title, isNot(unknown.title));
      expect(unsupported.consequence, isNot(unknown.consequence));
      expect(unsupported.needsConfirmation, isTrue);
      expect(unknown.needsConfirmation, isFalse);
    });

    test('the unsupported warning names the party that can act', () {
      // Without that clause the user is left thinking there is a setting here
      // they have not found yet.
      const warning = MamChangeWarning(
        MamChangeKind.mayNotTakeEffect,
        'title',
        'consequence',
        needsConfirmation: false,
      );
      expect(warning.kind, MamChangeKind.mayNotTakeEffect);
      expect(
        MamChangeWarning.mayNotTakeEffect(MamPrefsSupport.unsupported)
            .consequence,
        contains('whoever runs the server can'),
      );
    });

    test('the shorter-retention warning says the setting does not delete', () {
      // The specific sentence the module promises to say *beforehand*. A user
      // who learns it afterwards has been told something the setting cannot
      // deliver, and will reasonably conclude the app deleted things it did
      // not — and will not try the setting again.
      const warning = MamChangeWarning.shorterRetention();
      expect(warning.kind, MamChangeKind.shorterRetention);
      expect(warning.title, contains('not delete'));
      expect(warning.consequence, contains('not deleted'));
      expect(
        warning.needsConfirmation,
        isTrue,
        reason: 'this is the one dialog that must block the change',
      );
    });

    test('every warning carries a kind, a title and a consequence', () {
      // A warning an interface cannot render is a warning the user never sees,
      // and the change goes through unannounced — which is the failure the
      // shorter-retention warning exists to prevent.
      for (final support in MamPrefsSupport.values) {
        for (final warning in [
          const MamChangeWarning.shorterRetention(),
          const MamChangeWarning.unknownCurrent(),
          MamChangeWarning.mayNotTakeEffect(support),
        ]) {
          expect(warning.title.trim(), isNotEmpty, reason: '$support');
          expect(warning.consequence.trim(), isNotEmpty, reason: '$support');
        }
      }
    });

    test('no warning claims that anything was deleted', () {
      // Swept over every combination the function can produce. Not one of them
      // may assert that the server has dropped anything: nothing in this
      // protocol removes anything, and a sentence saying otherwise is a promise
      // the code cannot keep.
      for (final current in states) {
        for (final next in states) {
          for (final support in MamPrefsSupport.values) {
            for (final warning in warningsBeforeChange(
              current: current,
              next: next,
              support: support,
            )) {
              expect(
                RegExp(r'\bhas deleted\b|\bwere deleted\b|\bdeleted them\b')
                    .hasMatch('${warning.title} ${warning.consequence}'),
                isFalse,
                reason: '$current → $next on $support: ${warning.consequence}',
              );
            }
          }
        }
      }
    });
  });

  // ---------------------------------------------------------------------
  group('the two states a comparison cannot rank', () {
    test('FINDING: a cap-only state can be ranked against `never`', () {
      // FINDING — kept failing rather than weakened.
      //
      // What the doc claims: `shortensRetention` is "true when [next] leaves the
      // server keeping strictly less than [current]", and false "whenever the
      // two cannot be ranked against each other — not because they compare
      // equal, but because 'we cannot tell' is not evidence of a reduction".
      //
      // What the code does: when one side states no policy at all (`exposure` is
      // null) and the other does, it returns false *before* looking at the
      // caps. That is right in the direction where the policy side is more
      // permissive — we genuinely cannot tell — and wrong in the other. A
      // `<prefs max='30'/>` says the server is keeping *some* messages for a
      // month; `never` says it is keeping *none*. One is strictly less than the
      // other, nothing about the pair is unrankable, and no warning is produced
      // for the single most privacy-restrictive change in this protocol.
      //
      // Which is right: the code should be. This is the warning the module
      // exists for. A user moving from "keeps some messages for a month" to
      // "keeps none" is doing the thing `warningsBeforeChange` was written to
      // say something about and hears nothing. The stated cost of warning is
      // "warn on every unrankable change", and this pair is not one of them, so
      // the cost argument does not reach it either.
      final silent = <String>[
        for (final current in capOnly)
          for (final next in neverVariants)
            if (!shortensRetention(current, next)) '$current → $next',
      ];
      expect(
        silent,
        isEmpty,
        reason: 'the most restrictive change in the protocol said nothing',
      );
    });

    test('and the fix must not make every cap-only pair rankable', () {
      // A guard on the fix above, not a defect of its own — and the reason it is
      // worth writing down:
      // "Keeps some messages for a month" and "keeps only your group chat
      // messages" have no honest ordering: the first could be more or less than
      // the second. The doc's "false whenever the two cannot be ranked" clause
      // covers exactly this, and the code gets it right. Asserted so the two
      // cases cannot be merged: a fix that made the cap-only comparison total
      // would also make this one total, and that would be the wrong fix —
      // claiming `always` shortens `onlyMuc` would put a privacy dialog on a
      // change nobody can describe.
      for (final current in capOnly) {
        final next = state(MamRetention.onlyMuc, maxDays: 30);
        expect(
          shortensRetention(current, next),
          isFalse,
          reason: '$current → $next is genuinely unrankable',
        );
      }
    });

    test('two cap-only states still compare, on their caps', () {
      // "Both null is not this case: two cap-only policies compare fine, on
      // their caps." The one place a pair with no policy on either side *is*
      // comparable, and it must be.
      for (final from in [1, 7, 30, 365]) {
        for (final to in [1, 7, 30, 365]) {
          expect(
            shortensRetention(
              RetentionPolicy.days(from),
              RetentionPolicy.days(to),
            ),
            to < from,
            reason: 'cap-only $from → $to',
          );
        }
      }
    });

    test('`unknown` and `unsupported` are told apart from each other', () {
      // Three states because the consequences are three. Collapsing `unknown`
      // into `unsupported` would tell a user on a slow network that their
      // server has no archive control at all; collapsing it into `supported`
      // would show a retention control whose effect nobody has confirmed.
      expect(MamPrefsSupport.values, hasLength(3));
      expect(MamPrefsSupport.values.toSet(), hasLength(3));
      expect(MamPrefsSupport.unknown, isNot(MamPrefsSupport.unsupported));
      expect(MamPrefsSupport.unknown.honoured, isFalse);
      expect(MamPrefsSupport.unsupported.honoured, isFalse);
    });
  });

  // ---------------------------------------------------------------------
  group('the wire form', () {
    test('an element in another namespace is not read as preferences', () {
      // A stanza can carry children from several namespaces, and reading a
      // `<prefs/>` from the wrong one is how a MAM *query* form ends up read as
      // a retention setting. Null means "not this form", never "an empty form":
      // the two lead to opposite screens.
      for (final namespace in ['urn:xmpp:mam:2', 'jabber:iq:prefs', '']) {
        expect(
          parseMamPrefs(
            MamPrefsElement(
              MamPrefsForm.prefsElement,
              namespace: namespace,
              attributes: {MamPrefsForm.attrDefault: 'never'},
            ),
          ),
          isNull,
          reason: 'namespace "$namespace"',
        );
      }
      expect(
        parseMamPrefs(
          const MamPrefsElement(
            MamPrefsForm.prefsElement,
            attributes: {MamPrefsForm.attrDefault: 'never'},
          ),
        ),
        isNotNull,
      );
    });

    test('an element of another name is not read as preferences', () {
      for (final name in ['query', 'message', 'with', 'result']) {
        expect(
          parseMamPrefs(
            MamPrefsElement(
              name,
              attributes: {MamPrefsForm.attrDefault: 'never'},
            ),
          ),
          isNull,
          reason: 'element <$name>',
        );
      }
    });

    test('an empty form is an answer, not an absence', () {
      // `parseMamPrefs` returns null only for "this is not the preferences
      // form". A `<prefs/>` carrying nothing is the server saying it has no
      // preference set, and conflating the two either hides a control that
      // works or invents one that does not.
      final parsed = parseMamPrefs(
        const MamPrefsElement(MamPrefsForm.prefsElement),
      );
      expect(parsed, isNotNull);
      expect(parsed!.defaultRetention, isNull);
      expect(parsed.overrides, isEmpty);
    });

    test('a default is read only when the element states one', () {
      // A `to` attribute says which archive the answer is about, not what is
      // kept in it. Reading it as a policy statement would put an answer about
      // *where* into the sentence about *what*.
      expect(
        parseMamPrefs(const MamPrefsElement(MamPrefsForm.prefsElement))!
            .defaultRetention,
        isNull,
      );
      expect(
        parseMamPrefs(
          const MamPrefsElement(
            MamPrefsForm.prefsElement,
            attributes: {MamPrefsForm.attrTo: 'phone'},
          ),
        )!.defaultRetention,
        isNull,
        reason: 'a `to` is not a statement about what is kept',
      );
      expect(
        parseMamPrefs(
          const MamPrefsElement(
            MamPrefsForm.prefsElement,
            attributes: {MamPrefsForm.attrDefault: 'never'},
          ),
        )!.defaultRetention,
        state(MamRetention.never),
      );
    });

    test('an unknown element inside the form costs us nothing we could read', () {
      // A server extending the form must not turn into "we have no
      // preferences". Each unknown child is dropped and the `<with/>` beside it
      // is still read, which is what keeps a working control working.
      for (final child in elements) {
        final parsed = parseMamPrefs(
          MamPrefsElement(
            MamPrefsForm.prefsElement,
            attributes: {MamPrefsForm.attrDefault: 'never'},
            children: [child],
          ),
        )!;
        expect(
          parsed.defaultRetention,
          state(MamRetention.never),
          reason: 'child ${child.toXml()}',
        );
        expect(
          parsed.overrides.length,
          child.name == MamPrefsForm.withElement ? 1 : 0,
          reason: 'child ${child.toXml()}',
        );
      }
    });

    test('a `<with/>` naming no JID is dropped rather than guessed at', () {
      // Dropping is the only option and dropping is permissive — whoever it was
      // meant for goes back to the account default — so the honest response is
      // not to guess which conversation was meant. The one thing that must
      // survive is the entries we *can* read, either side of the bad one.
      for (final missing in missingJids) {
        final parsed = parseMamPrefs(
          MamPrefsElement(
            MamPrefsForm.prefsElement,
            attributes: {MamPrefsForm.attrDefault: 'never'},
            children: [
              MamPrefsElement(
                MamPrefsForm.withElement,
                attributes: {MamPrefsForm.attrDefault: 'always'},
              ),
              if (missing != null)
                MamPrefsElement(
                  MamPrefsForm.withElement,
                  attributes: {
                    MamPrefsForm.attrJid: missing,
                    MamPrefsForm.attrDefault: 'always',
                  },
                ),
              const MamPrefsElement(
                MamPrefsForm.withElement,
                attributes: {MamPrefsForm.attrJid: juliet, 'default': 'always'},
              ),
            ],
          ),
        )!;
        expect(parsed.overrides.keys, [
          juliet,
        ], reason: 'a jid of ${missing == null ? 'nothing' : '""'}');
        expect(
          effectiveRetention(prefs: parsed, conversation: juliet),
          state(MamRetention.always),
        );
      }
    });

    test('FINDING: and a JID that is only whitespace names nothing either', () {
      // FINDING — kept failing rather than weakened, though it is the mildest
      // of the five.
      //
      // What the doc claims: "A `<with/>` naming no JID cannot be applied to any
      // conversation. Dropping it is the only option and dropping it is
      // permissive — it puts whoever it was meant for back on the account
      // default." The check is `jid == null || jid.isEmpty`.
      //
      // What the code does: keeps `jid=' '` as an override under the key `' '`,
      // so the form carries a conversation that does not exist, and the
      // account's list of per-conversation settings gains a blank row.
      //
      // Which is right: the code should drop it. It is not a privacy hole —
      // the entry is still findable by the same string, so nothing falls back
      // to the default — but it is the same "names no conversation" case the
      // comment says must be dropped, and it puts a blank conversation in a
      // list a user reads to find out what the server holds.
      final kept = <String>[
        for (final blank in const [' ', '  ', '\t'])
          if (parseMamPrefs(
            MamPrefsElement(
              MamPrefsForm.prefsElement,
              children: [
                MamPrefsElement(
                  MamPrefsForm.withElement,
                  attributes: {
                    MamPrefsForm.attrJid: blank,
                    MamPrefsForm.attrDefault: 'never',
                  },
                ),
              ],
            ),
          )!.overrides.isNotEmpty)
            '"$blank"',
      ];
      expect(kept, isEmpty, reason: 'a blank JID is not a conversation');
    });

    test('an unreadable policy inside a `<with/>` is still an entry', () {
      // Leaving the entry out would mean "falls back to the account default",
      // which is a different and more permissive claim than "the server said
      // something about this conversation that we cannot describe".
      for (final token in tokens) {
        final parsed = parseMamPrefs(
          MamPrefsElement(
            MamPrefsForm.prefsElement,
            attributes: {MamPrefsForm.attrDefault: 'never'},
            children: [
              MamPrefsElement(
                MamPrefsForm.withElement,
                attributes: {
                  MamPrefsForm.attrJid: juliet,
                  MamPrefsForm.attrDefault: ?token,
                },
              ),
            ],
          ),
        )!;
        expect(
          parsed.overrides.containsKey(juliet),
          isTrue,
          reason: 'default token ${token ?? 'absent'}',
        );
        final entry = parsed.overrides[juliet]!;
        final recognised = token == null ? null : MamRetention.parse(token);
        expect(entry.policy, recognised, reason: 'default token "$token"');
        expect(
          entry.unrecognised,
          recognised == null && token != null ? token : null,
          reason: 'default token "$token"',
        );
        expect(
          effectiveRetention(prefs: parsed, conversation: juliet),
          entry,
          reason:
              'an entry we cannot describe must not fall back to the default',
        );
      }
    });

    test('a malformed stanza never stops the client working', () {
      // The parser's contract, stated in `RetentionPolicy`'s comment: "a
      // hostile stanza gets a recorded loss, never an exception". A stanza from
      // the server the user is reading their own history through is not a
      // reason for the app to fail to start.
      for (final token in tokens) {
        for (final max in readCaps.keys) {
          expect(
            () => parseRetention(token, max: max),
            returnsNormally,
            reason: 'token ${token ?? 'absent'}, max ${max ?? 'absent'}',
          );
        }
      }
    });

    test('an unreadable cap is left out rather than guessed at', () {
      // "a server sending `max='0'` or `max='soon'` has told us it intended a
      // limit, and inventing one — 'forever', or 'zero days' — is worse than
      // admitting we lost the number." So no cap may come back as a number it
      // is not, and a lost cap must read as unknown rather than as unbounded.
      for (final entry in readCaps.entries) {
        final parsed = parseRetention('always', max: entry.key);
        expect(
          parsed.policy,
          MamRetention.always,
          reason: 'max "${entry.key}"',
        );
        expect(parsed.maxDays, entry.value, reason: 'max "${entry.key}"');
        if (entry.value == null) {
          expect(
            privacySummary(prefsWith(parsed)),
            contains('has not said when it will delete them'),
            reason: 'a lost cap must read as unknown, not as unbounded',
          );
        }
      }
    });

    test('`max` on its own is a cap with no policy, not an absence', () {
      // The server said how long and not what. Reporting nothing here would
      // discard the one fact it did tell us, and reporting a guessed policy
      // would invent the other one.
      final parsed = parseMamPrefs(
        const MamPrefsElement(
          MamPrefsForm.prefsElement,
          attributes: {MamPrefsForm.attrMax: '30'},
        ),
      )!;
      expect(parsed.defaultRetention, isNotNull);
      expect(parsed.defaultRetention!.policy, isNull);
      expect(parsed.defaultRetention!.maxDays, 30);
      expect(privacySummary(parsed), contains('30 days'));
      expect(privacySummary(parsed), contains('has not said which'));
    });

    test('an unrecognised token goes back out as itself, not dropped', () {
      // The difference between "this client does not understand the policy" and
      // "there is no policy here". Collapsing them on the way out would turn the
      // server's word into silence and, if the result were echoed back, into a
      // `set` that removes a setting.
      final wire = toPrefsElement(
        prefsWith(state(null, unrecognised: 'weird-policy')),
      );
      expect(
        wire.toXml(),
        contains("default='weird-policy'"),
        reason: wire.toXml(),
      );
      final back = parseMamPrefs(wire)!;
      expect(back.defaultRetention!.unrecognised, 'weird-policy');
      expect(back.defaultRetention!.policy, isNull);
    });

    test('the whole form round trips, including what we cannot name', () {
      // A `set` built from a read must not quietly remove anything the read
      // gave us, so every state that says something goes out and comes back
      // identical — on the account and on one conversation at a time.
      for (final p in states.where(carriesSomething)) {
        for (final resource in [null, 'phone']) {
          final original = MamPrefs(
            resource: resource,
            defaultRetention: p,
            overrides: {juliet: state(MamRetention.roster, maxDays: 7)},
          );
          final wire = toPrefsElement(original);
          final back = parseMamPrefs(wire, resource: resource)!;
          expect(back.defaultRetention, p, reason: '$p on $resource');
          expect(
            back.overrides[juliet],
            state(MamRetention.roster, maxDays: 7),
            reason: '$p on $resource',
          );
          expect(back.resource, resource, reason: '$p on $resource');
          // And a second trip changes nothing, so a caller that echoes the
          // result of a write back to the server does not drift.
          expect(
            toPrefsElement(back).toXml(),
            wire.toXml(),
            reason: '$p on $resource',
          );
        }
      }
    });

    test('a state that carried nothing readable goes out as an empty form', () {
      // The one documented discard in the module: a cap we could not read is
      // left out "towards the *less* informative reading rather than the more
      // permissive one". It must therefore come back as an absence of
      // information, and never as a claim.
      final blank = state(null);
      expect(carriesSomething(blank), isFalse);
      final wire = toPrefsElement(prefsWith(blank));
      expect(wire.attributes, isEmpty, reason: wire.toXml());
      expect(wire.children, isEmpty, reason: wire.toXml());
      final back = parseMamPrefs(wire)!;
      expect(back.defaultRetention, isNull);
      expect(privacySummary(back), contains('has not said'));
    });

    test('overrides are written in a stable order', () {
      // "A form whose element order depends on a Map's internal iteration is a
      // form that produces a different stanza and a different log line for the
      // same settings." Two insertions of the same set must produce identical
      // XML, and in sorted order.
      final a = prefsWith(
        null,
        overrides: {
          juliet: state(MamRetention.never),
          'tybalt@capulet.lit': state(MamRetention.roster),
          'paris@capulet.lit': state(MamRetention.onlyMuc),
        },
      );
      final b = prefsWith(
        null,
        overrides: {
          'paris@capulet.lit': state(MamRetention.onlyMuc),
          juliet: state(MamRetention.never),
          'tybalt@capulet.lit': state(MamRetention.roster),
        },
      );
      expect(toPrefsElement(a).toXml(), toPrefsElement(b).toXml());
      expect(
        toPrefsElement(a).toXml(),
        "<prefs><with jid='juliet@capulet.lit' default='never'/>"
        "<with jid='paris@capulet.lit' default='only-muc'/>"
        "<with jid='tybalt@capulet.lit' default='roster'/></prefs>",
      );
    });

    test('every element the module emits is in the preferences namespace', () {
      // Reading a `<prefs/>` from the wrong namespace is how a MAM query form
      // ends up read as a retention setting, and it is a mistake the emitter
      // can prevent rather than the parser having to catch.
      for (final p in states) {
        final wire = toPrefsElement(prefsWith(p, overrides: {juliet: p}));
        expect(wire.namespace, MamPrefsForm.namespace, reason: '$p');
        expect(wire.name, MamPrefsForm.prefsElement, reason: '$p');
        for (final child in wire.children) {
          expect(child.namespace, MamPrefsForm.namespace, reason: '$p');
          expect(child.name, MamPrefsForm.withElement, reason: '$p');
        }
      }
    });

    test('the form names the same elements and attributes throughout', () {
      // The constants live next to the code that interprets them "so the two
      // cannot drift apart". Written as literals on either side, they could
      // drift and nothing would notice until a real server answered.
      expect(MamPrefsForm.namespace, 'urn:xmpp:mam:prefs:0');
      expect(MamPrefsForm.prefsElement, 'prefs');
      expect(MamPrefsForm.withElement, 'with');
      expect(MamPrefsForm.attrDefault, 'default');
      expect(MamPrefsForm.attrMax, 'max');
      expect(MamPrefsForm.attrJid, 'jid');
      expect(MamPrefsForm.attrTo, 'to');
      expect(MamPrefsForm.iqTypeGet, 'get');
      expect(MamPrefsForm.iqTypeSet, 'set');
      expect(MamPrefsForm.iqTypeGet, isNot(MamPrefsForm.iqTypeSet));
    });

    test('the set form carries the whole state, not a merge', () {
      // `MamPrefs` is the *whole* desired state, so narrowing one thing must
      // not quietly drop another: an override that vanishes from a `set` is
      // removed on the server.
      final full = prefsWith(
        state(MamRetention.never),
        overrides: {
          juliet: state(MamRetention.never),
          'tybalt@capulet.lit': state(MamRetention.roster),
        },
      );
      final wire = toPrefsElement(full.withDefault(state(MamRetention.roster)))
          .toXml();
      expect(wire, contains("default='roster'"));
      expect(wire, contains("jid='juliet@capulet.lit'"));
      expect(wire, contains("jid='tybalt@capulet.lit'"));
    });
  });

  // ---------------------------------------------------------------------
  group('the invariant that runs through all of it', () {
    test('nothing here turns an unreadable answer into a permission', () {
      // The line `resolveTrack` draws when a device list cannot be read, and
      // `capabilities.dart` draws with `reliable: false`. Absent evidence is
      // never permission and here it is specifically never "keep my history
      // forever". Swept over every state that means "we do not know".
      for (final p in <RetentionPolicy?>[
        null,
        ...states.where((p) => p.policy == null),
      ]) {
        final prefs = prefsWith(p);
        expect(
          effectiveRetention(prefs: prefs, conversation: juliet),
          p,
          reason: '$p',
        );
        expect(
          privacySummary(prefs),
          isNot(contains('with no limit on how long')),
          reason: '$p must not claim an unbounded period',
        );
      }
      for (final support in [
        MamPrefsSupport.unknown,
        MamPrefsSupport.unsupported,
      ]) {
        expect(serverSupportsMamPrefs(support), isFalse, reason: '$support');
        expect(support.honoured, isFalse, reason: '$support');
        expect(
          mayWritePreferences(support: support, current: MamPrefs()),
          isFalse,
          reason: '$support',
        );
        expect(
          warningsBeforeChange(
            current: state(MamRetention.always),
            next: state(MamRetention.never),
            support: support,
          ).map((w) => w.kind),
          contains(MamChangeKind.mayNotTakeEffect),
          reason: '$support must say the change may not take effect',
        );
      }
    });

    test('`keepsNothing` is true for one state only', () {
      // Swept over the whole space. This getter is what an interface would use
      // to hide an archive control, so a false positive tells a user their
      // history is not being kept when it is — the mistake the doc calls worse
      // than the opposite one, because a wrong reassurance gets believed.
      expect(states.where((p) => p.keepsNothing).toList(), [
        state(MamRetention.never),
      ]);
    });

    test('`exposure` is null exactly when the policy is unreadable', () {
      // "Null is a real answer and has to stay distinguishable from a low rank:
      // 'we do not know' is not 'keeps very little'." If an unreadable state
      // reported exposure 0, a caller ranking two states would rank it below
      // `never` and conclude it shortens.
      for (final p in states) {
        expect(p.exposure == null, p.policy == null, reason: '$p');
        if (p.policy != null) {
          expect(p.exposure, p.policy!.exposure, reason: '$p');
        }
      }
    });

    test('two equal policies are equal, and unequal ones are not', () {
      // These go in a `Map` and are compared to decide whether a re-read
      // changed anything. A broken `==` makes "no change" look like a change,
      // and the user gets warned about a save they did not make.
      for (final a in states) {
        expect(a, a, reason: 'reflexive for $a');
        for (final b in states) {
          if (a == b) {
            expect(a.hashCode, b.hashCode, reason: '$a vs $b');
          }
        }
      }
      expect(
        state(MamRetention.always, maxDays: 30),
        state(MamRetention.always, maxDays: 30),
      );
      expect(
        state(MamRetention.always, maxDays: 30),
        isNot(state(MamRetention.always, maxDays: 7)),
      );
      expect(state(MamRetention.always), isNot(state(MamRetention.unlimited)));
      expect(
        state(null, unrecognised: 'weird'),
        isNot(state(null, unrecognised: 'other')),
      );
    });

    test('no function in the module throws for any state it can be handed', () {
      // Swept over the whole space. The connection layer reduces a stanza and
      // hands it here; anything that throws is a server stanza that has stopped
      // the client working, which is the one failure mode the whole design is
      // arranged against.
      for (final p in states) {
        final prefs = prefsWith(p, overrides: {juliet: p});
        expect(() => privacySummary(prefs), returnsNormally, reason: '$p');
        expect(
          () => conversationPrivacySummary(prefs, juliet),
          returnsNormally,
          reason: '$p',
        );
        expect(
          () => effectiveRetention(prefs: prefs, conversation: juliet),
          returnsNormally,
          reason: '$p',
        );
        expect(
          () => appliesToResource(prefs, 'phone'),
          returnsNormally,
          reason: '$p',
        );
        expect(() => toPrefsElement(prefs), returnsNormally, reason: '$p');
        expect(
          () => parseMamPrefs(toPrefsElement(prefs)),
          returnsNormally,
          reason: '$p',
        );
        for (final support in MamPrefsSupport.values) {
          expect(
            () => warningsBeforeChange(current: p, next: p, support: support),
            returnsNormally,
            reason: '$p on $support',
          );
          expect(
            () => mayWritePreferences(support: support, current: prefs),
            returnsNormally,
            reason: '$p on $support',
          );
        }
      }
    });

    test('`bareJid` keeps the domain and drops only the resource', () {
      // Swept over the forms a server can send. A truncation that removed too
      // much would collapse two people into one override; one that removed too
      // little would miss the override it filed, and both fail towards the
      // account default, which is the permissive direction.
      expect(bareJid(julietPhone), juliet);
      expect(bareJid(julietTablet), juliet);
      expect(bareJid(juliet), juliet);
      expect(
        bareJid('room@conference.example.org/nick'),
        'room@conference.example.org',
      );
      expect(bareJid('a/b/c'), 'a');
      expect(bareJid('@example.org'), '@example.org');
      expect(bareJid('no-at-sign'), 'no-at-sign');
      for (final jid in [
        juliet,
        julietPhone,
        julietTablet,
        'a/b/c',
        '@x',
        '',
      ]) {
        final prefs = prefsWith(
          null,
          overrides: {jid: state(MamRetention.never)},
        );
        expect(prefs.overrideFor(jid), isNotNull, reason: 'JID "$jid"');
        expect(
          prefs.overrideFor(bareJid(jid)),
          isNotNull,
          reason: 'JID "$jid" by its bare form',
        );
      }
    });

    test('the sweeps really are the whole space, in both directions', () {
      // A sweep that quietly shrank would still pass every test that uses it
      // while testing less. The counts are asserted so that a later edit which
      // drops a state cannot hide.
      expect(states, hasLength(42));
      expect(
        states.toSet(),
        hasLength(42),
        reason:
            'the states must be distinct or the sweep is smaller than it looks',
      );
      expect(everyPair().length, 42 * 42);
      expect(capOnly, isNotEmpty);
      expect(noReadablePolicy, isNotEmpty);
      expect(neverVariants, hasLength(2));
    });
  });
}
