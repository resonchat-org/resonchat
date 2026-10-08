// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The emoji catalogue behind the insertion panel.
//
// Two questions that are constantly conflated, and that this module keeps
// apart because they have different answers:
//
//   * What can the panel *display*? Anything the local font covers, including
//     sequences: ❤️, 👨‍👩‍👧 and 🇩🇪 are in the catalogue and all render on a
//     phone, as would a skin tone such as 👍🏽 if we cared to add it.
//   * What can we *send*? Only a single code point, because a reaction or a
//     sticker reply is drawn by somebody else's client. A sequence is where
//     clients disagree: a variation selector may be honoured or dropped, a skin
//     tone may or may not apply, and a ZWJ sequence may arrive as several
//     loose characters. The two sides then see different pictures for the same
//     reaction, which is the failure kQuickReactions already rules out for the
//     six quick ones.
//
// So the catalogue is display-complete and the sendable set is a subset of it.
// `sendableEmoji` is the subset (safe to send); `allEmoji` is the whole thing
// (safe to display); `displayOnlyEmoji` is exactly where the two lists diverge,
// and it is deliberately not empty — a data file whose two sets coincide has
// stopped expressing a distinction nobody would notice losing.
//
// The full Unicode emoji table is ~3,600 characters and megabytes of Dart
// source, which slows every build and every test in the repo to serve a panel
// nobody scrolls to the end of. This is three hundred and forty-odd, chosen as
// the characters people actually send in a messenger: the faces, the hands, the
// food, the flags. The cost is that 🦎 and 🧌 are missing, and that is the right
// trade — a smaller table is also a table a human can review, which is what
// keeps the bad characters out.
//
// This is data and logic only; the widgets that draw it live elsewhere. A panel
// sized by TgDimens.chatsRowHeight wants a grid, not a list of thousands.

/// The panel's tabs, in the order they are drawn.
///
/// [EmojiCategory.recent] is not one of these taxonomies and is here anyway:
/// "recently used" is usage, not meaning, but the panel needs it in the same
/// tab strip as the categories, and a second list to keep in step would drift
/// the first time a tab was added.
enum EmojiCategory {
  recent('Recent'),
  smileys('Smileys'),
  people('People'),
  animals('Animals'),
  food('Food'),
  activity('Activity'),
  travel('Travel'),
  objects('Objects'),
  symbols('Symbols'),
  flags('Flags');

  const EmojiCategory(this.label);

  /// English tab caption. Not localised yet, because a picker showing a
  /// half-translated tab list is worse than an untranslated one.
  final String label;
}

/// One row of the catalogue: the character, and the words that find it.
///
/// [name] is a plain ASCII phrase with space-separated words rather than one
/// run-together token, so a query can match a whole word ("heart") instead of
/// only ever matching a prefix of the name ("heart" against "heartshirt").
class EmojiEntry {
  const EmojiEntry(this.emoji, this.name);

  final String emoji;

  /// English short name, also the search index. ASCII by construction: a search
  /// box is a Latin keyboard, and a query can never equal a non-ASCII token.
  final String name;
}

/// What the recent tab shows before the user has used anything.
///
/// The same six characters as `kQuickReactions`, restated as literals. A
/// reaction and the top of the panel ought to offer the same set, and six
/// literals are cheaper than a dependency from a UI data module onto the XMPP
/// layer — which would drag drift and moxxmpp into every test of this file. If
/// that constant changes this must follow; nothing here can enforce that, which
/// is why the six below are also exactly the entries `isCategorySendable`
/// requires anyway.
const List<EmojiEntry> _recent = <EmojiEntry>[
  EmojiEntry('👍', 'thumbs up'),
  EmojiEntry('❤', 'heart'),
  EmojiEntry('😂', 'face with tears of joy'),
  EmojiEntry('😮', 'face with open mouth'),
  EmojiEntry('😢', 'crying face'),
  EmojiEntry('🙏', 'folded hands'),
];

const List<EmojiEntry> _smileys = <EmojiEntry>[
  EmojiEntry('😀', 'grinning face'),
  EmojiEntry('😄', 'grinning face with smiling eyes'),
  EmojiEntry('😅', 'grinning face with sweat'),
  EmojiEntry('🤣', 'rolling on the floor laughing'),
  EmojiEntry('😂', 'face with tears of joy'),
  EmojiEntry('🙂', 'slightly smiling face'),
  EmojiEntry('🙃', 'upside down face'),
  EmojiEntry('😉', 'winking face'),
  EmojiEntry('😇', 'smiling face with halo'),
  EmojiEntry('🥰', 'smiling face with hearts'),
  EmojiEntry('😍', 'smiling face with heart eyes'),
  EmojiEntry('😘', 'face blowing a kiss'),
  EmojiEntry('😋', 'face savouring food'),
  EmojiEntry('🤪', 'zany face'),
  EmojiEntry('🤨', 'face with raised eyebrow'),
  EmojiEntry('🧐', 'face with monocle'),
  EmojiEntry('🥳', 'partying face'),
  EmojiEntry('😎', 'smiling face with sunglasses'),
  EmojiEntry('🤩', 'star struck'),
  EmojiEntry('🥺', 'pleading face'),
  EmojiEntry('😏', 'smirking face'),
  EmojiEntry('😒', 'unamused face'),
  EmojiEntry('🙄', 'face with rolling eyes'),
  EmojiEntry('😬', 'grimacing face'),
  EmojiEntry('🤐', 'zipper mouth face'),
  EmojiEntry('😔', 'pensive face'),
  EmojiEntry('😴', 'sleeping face'),
  EmojiEntry('🥵', 'hot face'),
  EmojiEntry('🥶', 'cold face'),
  EmojiEntry('🤯', 'exploding head'),
  EmojiEntry('🤠', 'cowboy hat face'),
  EmojiEntry('😈', 'smiling face with horns'),
  EmojiEntry('🤖', 'robot'),
  EmojiEntry('😮', 'face with open mouth'),
  EmojiEntry('😲', 'astonished face'),
  EmojiEntry('😨', 'fearful face'),
  EmojiEntry('😱', 'face screaming in fear'),
  EmojiEntry('😖', 'confounded face'),
  EmojiEntry('🥱', 'yawning face'),
  EmojiEntry('😤', 'face with steam from nose'),
  EmojiEntry('😡', 'enraged face'),
  EmojiEntry('😭', 'loudly crying face'),
  EmojiEntry('😢', 'crying face'),
  EmojiEntry('🤔', 'thinking face'),
  EmojiEntry('🫡', 'saluting face'),
  EmojiEntry('🤫', 'shushing face'),
  EmojiEntry('🤭', 'face with hand over mouth'),
  EmojiEntry('😶', 'face without mouth'),
];

const List<EmojiEntry> _people = <EmojiEntry>[
  EmojiEntry('👋', 'waving hand'),
  EmojiEntry('✋', 'raised hand'),
  EmojiEntry('🖐️', 'raised hand with fingers splayed'),
  EmojiEntry('🖖', 'vulcan salute'),
  EmojiEntry('✌️', 'victory hand'),
  EmojiEntry('🤞', 'crossed fingers'),
  EmojiEntry('🤟', 'love you gesture'),
  EmojiEntry('👌', 'ok hand'),
  EmojiEntry('🤏', 'pinching hand'),
  EmojiEntry('💅', 'nail polish'),
  EmojiEntry('👈', 'backhand index pointing left'),
  EmojiEntry('👉', 'backhand index pointing right'),
  EmojiEntry('👆', 'backhand index pointing up'),
  EmojiEntry('👇', 'backhand index pointing down'),
  EmojiEntry('☝️', 'index pointing up'),
  EmojiEntry('👍', 'thumbs up'),
  EmojiEntry('👎', 'thumbs down'),
  EmojiEntry('✊', 'raised fist'),
  EmojiEntry('👊', 'oncoming fist'),
  EmojiEntry('👏', 'clapping hands'),
  EmojiEntry('🙌', 'raising hands'),
  EmojiEntry('🤝', 'handshake'),
  EmojiEntry('🙏', 'folded hands'),
  EmojiEntry('💪', 'flexed biceps'),
  EmojiEntry('🧠', 'brain'),
  EmojiEntry('👀', 'eyes'),
  EmojiEntry('👶', 'baby'),
  EmojiEntry('🧒', 'child'),
  EmojiEntry('🧑', 'person'),
  EmojiEntry('👨', 'man'),
  EmojiEntry('👩', 'woman'),
  EmojiEntry('🧓', 'older person'),
  EmojiEntry('👮', 'police officer'),
  EmojiEntry('🧑‍🚀', 'astronaut'),
  EmojiEntry('🧑‍💻', 'technologist'),
  EmojiEntry('👩‍💻', 'woman technologist'),
  EmojiEntry('👨‍👩‍👧', 'family man woman girl'),
  EmojiEntry('👪', 'family'),
];

const List<EmojiEntry> _animals = <EmojiEntry>[
  EmojiEntry('🐶', 'dog face'),
  EmojiEntry('🐱', 'cat face'),
  EmojiEntry('🐰', 'rabbit face'),
  EmojiEntry('🦊', 'fox'),
  EmojiEntry('🐻', 'bear'),
  EmojiEntry('🐼', 'panda'),
  EmojiEntry('🦁', 'lion'),
  EmojiEntry('🐷', 'pig face'),
  EmojiEntry('🐔', 'chicken'),
  EmojiEntry('🐧', 'penguin'),
  EmojiEntry('🦉', 'owl'),
  EmojiEntry('🐺', 'wolf'),
  EmojiEntry('🐴', 'horse face'),
  EmojiEntry('🦄', 'unicorn'),
  EmojiEntry('🐝', 'honeybee'),
  EmojiEntry('🐛', 'bug'),
  EmojiEntry('🦋', 'butterfly'),
  EmojiEntry('🐜', 'ant'),
  EmojiEntry('🕷️', 'spider'),
  EmojiEntry('🐢', 'turtle'),
  EmojiEntry('🐍', 'snake'),
  EmojiEntry('🦎', 'lizard'),
  EmojiEntry('🐙', 'octopus'),
  EmojiEntry('🦑', 'squid'),
  EmojiEntry('🦀', 'crab'),
  EmojiEntry('🐬', 'dolphin'),
  EmojiEntry('🦈', 'shark'),
  EmojiEntry('🐊', 'crocodile'),
  EmojiEntry('🐘', 'elephant'),
  EmojiEntry('🦏', 'rhinoceros'),
  EmojiEntry('🦒', 'giraffe'),
  EmojiEntry('🦌', 'deer'),
  EmojiEntry('🦝', 'raccoon'),
];

const List<EmojiEntry> _food = <EmojiEntry>[
  EmojiEntry('🍎', 'red apple'),
  EmojiEntry('🍊', 'tangerine'),
  EmojiEntry('🍌', 'banana'),
  EmojiEntry('🍉', 'watermelon'),
  EmojiEntry('🍓', 'strawberry'),
  EmojiEntry('🫐', 'blueberries'),
  EmojiEntry('🍑', 'peach'),
  EmojiEntry('🥭', 'mango'),
  EmojiEntry('🍍', 'pineapple'),
  EmojiEntry('🍅', 'tomato'),
  EmojiEntry('🥔', 'potato'),
  EmojiEntry('🌽', 'corn'),
  EmojiEntry('🌶️', 'hot pepper'),
  EmojiEntry('🍞', 'bread'),
  EmojiEntry('🧀', 'cheese wedge'),
  EmojiEntry('🥚', 'egg'),
  EmojiEntry('🍳', 'cooking'),
  EmojiEntry('🍔', 'hamburger'),
  EmojiEntry('🍟', 'french fries'),
  EmojiEntry('🍕', 'pizza'),
  EmojiEntry('🌭', 'hot dog'),
  EmojiEntry('🌮', 'taco'),
  EmojiEntry('🍜', 'steaming bowl'),
  EmojiEntry('🍣', 'sushi'),
  EmojiEntry('🍪', 'cookie'),
  EmojiEntry('🎂', 'birthday cake'),
  EmojiEntry('🍰', 'shortcake'),
  EmojiEntry('🧁', 'cupcake'),
  EmojiEntry('🍫', 'chocolate bar'),
  EmojiEntry('🍬', 'candy'),
  EmojiEntry('🍯', 'honey pot'),
  EmojiEntry('☕', 'hot beverage'),
  EmojiEntry('🍵', 'teacup without handle'),
  EmojiEntry('🥤', 'cup with straw'),
  EmojiEntry('🍺', 'beer mug'),
  EmojiEntry('🍻', 'clinking beer mugs'),
  EmojiEntry('🍷', 'wine glass'),
  EmojiEntry('🍸', 'cocktail glass'),
  EmojiEntry('🥂', 'clinking glasses'),
];

const List<EmojiEntry> _activity = <EmojiEntry>[
  EmojiEntry('⚽', 'soccer ball'),
  EmojiEntry('🏀', 'basketball'),
  EmojiEntry('⚾', 'baseball'),
  EmojiEntry('🎾', 'tennis'),
  EmojiEntry('🏐', 'volleyball'),
  EmojiEntry('🏓', 'ping pong'),
  EmojiEntry('🥅', 'goal net'),
  EmojiEntry('⛳', 'flag in hole'),
  EmojiEntry('🏹', 'bow and arrow'),
  EmojiEntry('🎣', 'fishing pole'),
  EmojiEntry('🥊', 'boxing glove'),
  EmojiEntry('🥋', 'martial arts uniform'),
  EmojiEntry('🎽', 'running shirt'),
  EmojiEntry('🛹', 'skateboard'),
  EmojiEntry('🛼', 'roller skate'),
  EmojiEntry('⛸️', 'ice skate'),
  EmojiEntry('🏆', 'trophy'),
  EmojiEntry('🥇', 'first place medal'),
  EmojiEntry('🥈', 'second place medal'),
  EmojiEntry('🥉', 'third place medal'),
  EmojiEntry('🏅', 'sports medal'),
  EmojiEntry('🎯', 'bullseye'),
  EmojiEntry('🎮', 'video game'),
  EmojiEntry('🎲', 'game die'),
  EmojiEntry('🧩', 'puzzle piece'),
  EmojiEntry('🎨', 'artist palette'),
  EmojiEntry('🎤', 'microphone'),
  EmojiEntry('🎧', 'headphone'),
  EmojiEntry('🎹', 'musical keyboard'),
  EmojiEntry('🥁', 'drum'),
  EmojiEntry('🎸', 'guitar'),
];

const List<EmojiEntry> _travel = <EmojiEntry>[
  EmojiEntry('🚗', 'automobile'),
  EmojiEntry('🚕', 'taxi'),
  EmojiEntry('🚙', 'sport utility vehicle'),
  EmojiEntry('🚌', 'bus'),
  EmojiEntry('🚎', 'trolleybus'),
  EmojiEntry('🏎️', 'racing car'),
  EmojiEntry('🚓', 'police car'),
  EmojiEntry('🚑', 'ambulance'),
  EmojiEntry('🚒', 'fire engine'),
  EmojiEntry('🚚', 'delivery truck'),
  EmojiEntry('🚛', 'articulated lorry'),
  EmojiEntry('🚜', 'tractor'),
  EmojiEntry('🛵', 'motor scooter'),
  EmojiEntry('🏍️', 'motorcycle'),
  EmojiEntry('🚲', 'bicycle'),
  EmojiEntry('🛴', 'kick scooter'),
  EmojiEntry('🚦', 'vertical traffic light'),
  EmojiEntry('⛽', 'fuel pump'),
  EmojiEntry('🚂', 'locomotive'),
  EmojiEntry('✈️', 'airplane'),
  EmojiEntry('🚀', 'rocket'),
  EmojiEntry('🚁', 'helicopter'),
  EmojiEntry('⛵', 'sailboat'),
  EmojiEntry('⚓', 'anchor'),
  EmojiEntry('🚏', 'bus stop'),
  EmojiEntry('🗺️', 'world map'),
  EmojiEntry('🗿', 'moai'),
  EmojiEntry('🗽', 'statue of liberty'),
  EmojiEntry('🏰', 'castle'),
  EmojiEntry('🎡', 'ferris wheel'),
  EmojiEntry('🎢', 'roller coaster'),
  EmojiEntry('⛺', 'tent'),
  EmojiEntry('🏠', 'house'),
  EmojiEntry('🏖️', 'beach with umbrella'),
  EmojiEntry('🏔️', 'snow capped mountain'),
  EmojiEntry('⛰️', 'mountain'),
  EmojiEntry('🌋', 'volcano'),
  EmojiEntry('🗻', 'mount fuji'),
  EmojiEntry('🌅', 'sunrise'),
  EmojiEntry('🌇', 'sunset'),
  EmojiEntry('🌌', 'milky way'),
  EmojiEntry('🌠', 'shooting star'),
  EmojiEntry('♨️', 'hot springs'),
];

const List<EmojiEntry> _objects = <EmojiEntry>[
  EmojiEntry('⌚', 'watch'),
  EmojiEntry('📱', 'mobile phone'),
  EmojiEntry('☎️', 'telephone'),
  EmojiEntry('💻', 'laptop'),
  EmojiEntry('⌨️', 'keyboard'),
  EmojiEntry('🕹️', 'joystick'),
  EmojiEntry('📷', 'camera'),
  EmojiEntry('📺', 'television'),
  EmojiEntry('⏰', 'alarm clock'),
  EmojiEntry('⏳', 'hourglass done'),
  EmojiEntry('🔋', 'battery'),
  EmojiEntry('🔌', 'electric plug'),
  EmojiEntry('💡', 'light bulb'),
  EmojiEntry('🔦', 'flashlight'),
  EmojiEntry('🔍', 'magnifying glass tilted left'),
  EmojiEntry('🔒', 'locked'),
  EmojiEntry('🔓', 'unlocked'),
  EmojiEntry('🔔', 'bell'),
  EmojiEntry('📖', 'open book'),
  EmojiEntry('📚', 'books'),
  EmojiEntry('📝', 'memo'),
  EmojiEntry('✏️', 'pencil'),
  EmojiEntry('📌', 'pushpin'),
  EmojiEntry('📎', 'paperclip'),
  EmojiEntry('✂️', 'scissors'),
  EmojiEntry('📅', 'calendar'),
  EmojiEntry('🗑️', 'wastebasket'),
  EmojiEntry('🔑', 'key'),
  EmojiEntry('🧭', 'compass'),
  EmojiEntry('🧪', 'test tube'),
  EmojiEntry('🔬', 'microscope'),
  EmojiEntry('🛒', 'shopping cart'),
  EmojiEntry('🎁', 'wrapped gift'),
  EmojiEntry('🎈', 'balloon'),
  EmojiEntry('💳', 'credit card'),
];

const List<EmojiEntry> _symbols = <EmojiEntry>[
  EmojiEntry('❤️', 'red heart'),
  // The same heart without its variation selector, and therefore the one worth
  // sending. Both are catalogued because the panel is for display; only this
  // one is in `sendableEmoji`.
  EmojiEntry('❤', 'heart'),
  EmojiEntry('🧡', 'orange heart'),
  EmojiEntry('💛', 'yellow heart'),
  EmojiEntry('💚', 'green heart'),
  EmojiEntry('💙', 'blue heart'),
  EmojiEntry('💜', 'purple heart'),
  EmojiEntry('🖤', 'black heart'),
  EmojiEntry('🤍', 'white heart'),
  EmojiEntry('💔', 'broken heart'),
  EmojiEntry('❣️', 'heart exclamation'),
  EmojiEntry('💕', 'two hearts'),
  EmojiEntry('💯', 'hundred points'),
  EmojiEntry('💥', 'collision'),
  EmojiEntry('💫', 'dizzy'),
  EmojiEntry('💬', 'speech balloon'),
  EmojiEntry('💭', 'thought balloon'),
  EmojiEntry('👁️‍🗨️', 'eye in speech bubble'),
  EmojiEntry('⭐', 'star'),
  EmojiEntry('🌟', 'glowing star'),
  EmojiEntry('✨', 'sparkles'),
  EmojiEntry('⚡', 'high voltage'),
  EmojiEntry('🔥', 'fire'),
  EmojiEntry('🌈', 'rainbow'),
  EmojiEntry('☀️', 'sun'),
  EmojiEntry('☁️', 'cloud'),
  EmojiEntry('❄️', 'snowflake'),
  EmojiEntry('☃️', 'snowman'),
  EmojiEntry('✅', 'check mark button'),
  EmojiEntry('❌', 'cross mark'),
  EmojiEntry('➕', 'plus'),
  EmojiEntry('➖', 'minus'),
  EmojiEntry('❗', 'exclamation'),
  EmojiEntry('❓', 'question'),
  EmojiEntry('⚠️', 'warning'),
  EmojiEntry('🚫', 'prohibited'),
  EmojiEntry('🔴', 'red circle'),
  EmojiEntry('🟢', 'green circle'),
  EmojiEntry('🔵', 'blue circle'),
  EmojiEntry('⚫', 'black circle'),
  EmojiEntry('♥️', 'heart suit'),
  EmojiEntry('♦️', 'diamond suit'),
  EmojiEntry('🆗', 'ok'),
];

const List<EmojiEntry> _flags = <EmojiEntry>[
  EmojiEntry('🏁', 'chequered flag'),
  EmojiEntry('🚩', 'triangular flag'),
  EmojiEntry('🏳️', 'white flag'),
  EmojiEntry('🏳️‍🌈', 'rainbow flag'),
  EmojiEntry('🇩🇪', 'flag germany'),
  EmojiEntry('🇫🇷', 'flag france'),
  EmojiEntry('🇬🇧', 'flag united kingdom'),
  EmojiEntry('🇮🇹', 'flag italy'),
  EmojiEntry('🇵🇹', 'flag portugal'),
  EmojiEntry('🇧🇪', 'flag belgium'),
  EmojiEntry('🇸🇪', 'flag sweden'),
  EmojiEntry('🇳🇴', 'flag norway'),
  EmojiEntry('🇫🇮', 'flag finland'),
  EmojiEntry('🇮🇸', 'flag iceland'),
  EmojiEntry('🇭🇺', 'flag hungary'),
  EmojiEntry('🇷🇴', 'flag romania'),
  EmojiEntry('🇺🇸', 'flag united states'),
  EmojiEntry('🇨🇦', 'flag canada'),
  EmojiEntry('🇧🇷', 'flag brazil'),
  EmojiEntry('🇨🇱', 'flag chile'),
  EmojiEntry('🇮🇳', 'flag india'),
  EmojiEntry('🇨🇳', 'flag china'),
  EmojiEntry('🇯🇵', 'flag japan'),
  EmojiEntry('🇰🇷', 'flag south korea'),
  EmojiEntry('🇹🇭', 'flag thailand'),
  EmojiEntry('🇦🇺', 'flag australia'),
  EmojiEntry('🇳🇿', 'flag new zealand'),
];

/// Which tab an entry is filed under.
///
/// Declaration order is the tab order, and nothing else decides it: the panel
/// has no other source for which tab comes next.
const Map<EmojiCategory, List<EmojiEntry>> _catalogue =
    <EmojiCategory, List<EmojiEntry>>{
      EmojiCategory.recent: _recent,
      EmojiCategory.smileys: _smileys,
      EmojiCategory.people: _people,
      EmojiCategory.animals: _animals,
      EmojiCategory.food: _food,
      EmojiCategory.activity: _activity,
      EmojiCategory.travel: _travel,
      EmojiCategory.objects: _objects,
      EmojiCategory.symbols: _symbols,
      EmojiCategory.flags: _flags,
    };

/// The entries filed under [category], in catalogue order.
List<EmojiEntry> emojiIn(EmojiCategory category) => _catalogue[category]!;

/// Every entry exactly once: category order, then order within the category.
///
/// [EmojiCategory.recent] is skipped. Recency is a *view* over the catalogue,
/// not a second copy of it, so the seed holds entries that already exist under
/// smileys and people and appending them here would list those two twice in the
/// flat list — and a search for `thumbs up` that returned two thumbs would
/// look like a bug in the search rather than in the data.
///
/// The order is a property of the source file, so it is the same in every
/// process, on every launch and on every device. That is not an aesthetic
/// choice. A panel whose results reorder between two keystrokes — because the
/// order came from a hash set, a frequency counter or a `Map` keyed by
/// something incidental — reads as broken long before anyone can explain why:
/// the user watched the emoji move while they were looking at it.
final List<EmojiEntry> allEmoji = List<EmojiEntry>.unmodifiable(<EmojiEntry>[
  for (final category in EmojiCategory.values)
    if (category != EmojiCategory.recent) ..._catalogue[category]!,
]);

/// The subset that is safe to *send*: one code point per entry.
///
/// This is the intersection of what a local font draws and what another client
/// will draw identically, and it is what a reaction or a sticker reply must be
/// drawn from. See `isSendableEmoji` for the rule.
final List<EmojiEntry> sendableEmoji = List<EmojiEntry>.unmodifiable(
  allEmoji.where((entry) => isSendableEmoji(entry.emoji)),
);

/// Entries that display here but must not be sent: a variation selector, a
/// skin tone, a ZWJ join, or a regional-indicator pair.
///
/// Everything in this list renders correctly in the panel, which is exactly why
/// it is dangerous in a *sent* reaction: we can see that it worked, and the
/// person on the other end may not get the same picture. Nothing in the UI may
/// quietly widen the sendable set with these.
final List<EmojiEntry> displayOnlyEmoji = List<EmojiEntry>.unmodifiable(
  allEmoji.where((entry) => !isSendableEmoji(entry.emoji)),
);

/// How many results a search hands back.
///
/// Bounded because the panel draws every hit in one grid: a query of one letter
/// otherwise matches most of the catalogue, which is the panel showing
/// everything again and telling the user nothing about the query.
const int kSearchLimit = 60;

/// Entries matching [query], best match first, at most [limit] of them.
///
/// Case-insensitive, matched against the whole name and against each word
/// of the name, so `heart`, `red heart` and `hear` all reach the hearts.
/// An empty or whitespace-only query returns nothing: the panel shows the
/// full category grid for no query at all, and a blank search box that dumps
/// the whole catalogue looks like the search ignored the user.
///
/// The ranking ladder, first match wins:
///
///   0. the query is the whole name        `red heart`
///   1. the query is a whole word in it    `broken heart` for `heart`
///   2. the name starts with the query     `thumbs up` for `thumb`
///   3. a word starts with the query       `face with tears of joy` for `tear`
///   4. the query appears inside it        `flag thailand` for `land`
///   5. a word contains the query          `shortcake` for `cake`
///
/// A whole-word hit always outranks a part-word one, and each rung keeps the
/// one below it reachable, so typing one more character narrows the list
/// instead of reshuffling it. Ties — two entries that rank equally — keep
/// catalogue order, which is the property that stops the grid moving under
/// the finger.
List<EmojiEntry> searchEmoji(String query, {int limit = kSearchLimit}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const <EmojiEntry>[];
  if (limit <= 0) return const <EmojiEntry>[];

  final hits = <_Hit>[];
  for (var i = 0; i < allEmoji.length; i++) {
    final entry = allEmoji[i];
    final rank = _rank(entry, needle);
    if (rank != null) hits.add(_Hit(rank, i, entry));
  }
  // The comparator settles ties explicitly rather than relying on the sort being
  // stable: whether List.sort preserves the order of equal elements is a
  // property of the implementation, not of this contract, and a version bump that
  // changed it would move emoji in a panel nobody touched.
  hits.sort((a, b) => a.rank != b.rank ? a.rank - b.rank : a.index - b.index);
  return List<EmojiEntry>.unmodifiable(
    hits.take(limit).map((hit) => hit.entry),
  );
}

/// One catalogue entry, the rung it matched on, and where it sits.
///
/// A plain class rather than a named-field record. Named record fields do not
/// resolve on this SDK — `h.rank` on `typedef H = (int rank, int index, E e)`
/// is an `undefined_getter` on Dart 3.13.4, and the analyzer reports only the
/// first failure per line, so it reads as though only some of the names are
/// missing. Positional `$1` access does work, but naming the parts is what makes
/// the comparator above legible, and the whole point of that comparator is that a
/// reader can check it by eye.
class _Hit {
  const _Hit(this.rank, this.index, this.entry);

  final int rank;
  final int index;
  final EmojiEntry entry;
}

/// The best rung [entry] matches on [needle], or null when it does not match.
int? _rank(EmojiEntry entry, String needle) {
  final name = entry.name.toLowerCase();
  if (name == needle) return 0;
  final words = name.split(' ');
  for (final word in words) {
    if (word == needle) return 1;
  }
  if (name.startsWith(needle)) return 2;
  for (final word in words) {
    if (word.startsWith(needle)) return 3;
  }
  if (name.contains(needle)) return 4;
  for (final word in words) {
    if (word.contains(needle)) return 5;
  }
  return null;
}

/// Whether [value] is something the emoji standard defines a glyph for.
///
/// This is the "would this be two boxes" question, and it is answered by
/// character set rather than by font: no static list can know what the reader's
/// phone ships, so the honest test is whether the string is built out of
/// characters the standard assigns. Text, digits, punctuation and control
/// characters are therefore the failure this catches, and they are exactly what
/// a hand-edited or machine-generated emoji list picks up.
///
/// A joiner or a variation selector on its own is also a failure, even though
/// both are legal Unicode: alone they have no glyph, so a string that is only
/// `\u200D\uFE0F` is two invisible boxes rather than one emoji.
bool isRenderableEmoji(String value) {
  if (value.isEmpty) return false;
  var sawGlyph = false;
  for (final rune in value.runes) {
    if (_isEmojiRune(rune)) {
      sawGlyph = true;
    } else if (rune != _zwj && rune != _vs16) {
      return false;
    }
  }
  return sawGlyph;
}

/// Whether [value] is one code point, and so safe to send to someone else.
///
/// Only single code points are in the sendable set.
///
/// A reaction travels to another person and is drawn by their client. U+2764
/// plus U+FE0F is two code points, and whether the trailing variation selector
/// produces a coloured pictograph or a monochrome glyph is decided by their
/// font — so the same reaction looks different to each of you. See
/// kQuickReactions for the same rule applied to the six quick ones, and
/// `displayOnlyEmoji` for the entries this rule keeps out.
///
/// One code point cannot disagree with itself: whatever the receiving client
/// draws, it draws from the same bytes we sent. That the two clients may then
/// draw it *identically as a monochrome glyph* is not a counterexample — the
/// failure this prevents is one side seeing a colour and the other not.
bool isSendableEmoji(String value) {
  final runes = value.runes;
  // `runes.length == 1` is the whole test, so it is checked first and the single
  // code point is then taken from the iterable rather than by index: `runeAt`
  // does not exist on String, and indexing `runes` would be a code-unit index
  // into a sequence whose elements are code points, which is the one mistake
  // that turns a supplementary-plane emoji into a false negative.
  return runes.length == 1 && _isEmojiRune(runes.first);
}

/// The entries of [category] that are not renderable, for a failing build.
List<String> unrenderableIn(EmojiCategory category) => <String>[
  for (final entry in _catalogue[category]!)
    if (!isRenderableEmoji(entry.emoji)) entry.emoji,
];

/// Whether every entry of [category] renders.
///
/// True for every category here, which is the point: the catalogue is the only
/// place a bad character can enter the app, so the check that matters is
/// the one on the data, not the one on a widget.
bool isCategoryRenderable(EmojiCategory category) =>
    unrenderableIn(category).isEmpty;

/// Whether every entry of [category] is safe to send.
///
/// True for [EmojiCategory.recent] and [EmojiCategory.smileys] today, and false
/// for the rest. Those categories happen to hold no sequences; the others file
/// them on purpose, so this returning false is the file's central distinction
/// rather than a defect to be fixed by deleting the sequences. A reaction
/// picker must read from `sendableEmoji`, never from a category.
bool isCategorySendable(EmojiCategory category) =>
    _catalogue[category]!.every((entry) => isSendableEmoji(entry.emoji));

/// U+200D. Legal Unicode, no glyph of its own.
const int _zwj = 0x200D;

/// U+FE0F. The trailing code point that decides whether ❤️ is colour.
const int _vs16 = 0xFE0F;

/// Whether [rune] is a code point the standard assigns a glyph to.
///
/// Enumerated block by block rather than expressed as one wide range:
/// `1F000..1FAFF` is mostly unassigned, and a validator that accepted
/// unassigned code points would pass exactly the strings a broken generator
/// produces — a replacement character or a private-use code point is a box, and
/// a box is the failure this exists to catch.
bool _isEmojiRune(int rune) =>
    (rune >= 0x231a && rune <= 0x231b) || // watch, hourglass
    rune == 0x2328 || // keyboard
    (rune >= 0x23e9 && rune <= 0x23f3) || // media controls, clocks, hourglass
    (rune >= 0x2600 && rune <= 0x27bf) || // misc symbols and dingbats
    (rune >= 0x2b00 && rune <= 0x2bff) || // arrows, stars, squares
    (rune >= 0x1f004 && rune <= 0x1f0cf) || // mahjong, playing cards
    (rune >= 0x1f190 && rune <= 0x1f1ff) || // squared keycap symbols
    (rune >= 0x1f1e6 && rune <= 0x1f1ff) || // regional indicators, i.e. flags
    (rune >= 0x1f300 && rune <= 0x1f5ff) || // pictographs, incl. skin tones
    (rune >= 0x1f600 && rune <= 0x1f64f) || // emoticons
    (rune >= 0x1f680 && rune <= 0x1f6ff) || // transport and map
    (rune >= 0x1f7e0 && rune <= 0x1f7ff) || // large coloured circles
    (rune >= 0x1f900 && rune <= 0x1f9ff) || // supplemental symbols and people
    (rune >= 0x1fa70 && rune <= 0x1faff); // symbols and pictographs extended-A
