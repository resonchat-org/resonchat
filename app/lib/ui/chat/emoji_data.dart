// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The emoji catalogue behind the insertion and reaction panels.
//
// What may appear as a reaction follows Gajim (`emoji.is_emoji` after stripping
// FE0E/FE0F): flags, skin tones, and ZWJ sequences are allowed; kaomoji and
// plain text are not. [isReactionEmoji] is that rule. [isRenderableEmoji] is
// the looser "is this catalogue glyph built from emoji code points" check used
// when drawing the panel.
//
// The full Unicode emoji table is ~3,600 characters and megabytes of Dart
// source, which slows every build and every test in the repo to serve a panel
// nobody scrolls to the end of. This is three hundred and forty-odd, chosen as
// the characters people actually send in a messenger: the faces, the hands, the
// food, the flags. The cost is that 🦎 and 🧌 are missing, and that is the right
// trade — a smaller table is also a table a human can review, which is what
// keeps the bad characters out.
//
// This is data and logic only; the widgets that draw it live elsewhere.

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
/// layer — which would drag drift and moxxmpp into every test of this file.
const List<EmojiEntry> _recent = <EmojiEntry>[
  EmojiEntry('👍', 'thumbs up'),
  EmojiEntry('💗', 'growing heart'),
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
  // Text-presentation heart (no FE0F). Kept for search; pickers exclude it
  // because Linux draws it black beside coloured emoji.
  EmojiEntry('❤', 'heart'),
  EmojiEntry('🧡', 'orange heart'),
  EmojiEntry('💗', 'growing heart'),
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

/// Strip leading/trailing emoji presentation selectors (U+FE0E / U+FE0F).
///
/// Matches Gajim's `normalize_reactions`: reactions must render as emoji, so
/// the selectors are redundant and stripping them unifies `❤` / `❤️`.
String stripEmojiPresentationSelectors(String value) {
  final runes = value.runes.toList(growable: false);
  var start = 0;
  var end = runes.length;
  while (start < end && (runes[start] == _vs15 || runes[start] == _vs16)) {
    start++;
  }
  while (end > start && (runes[end - 1] == _vs15 || runes[end - 1] == _vs16)) {
    end--;
  }
  if (start == 0 && end == runes.length) return value;
  return String.fromCharCodes(runes.sublist(start, end));
}

/// Whether [value] may be used as a reaction (XEP-0444), Gajim-aligned.
///
/// Gajim accepts any `emoji.is_emoji` after stripping presentation selectors —
/// including flags, skin tones, and ZWJ sequences — and rejects plain text /
/// kaomoji. [isRenderableEmoji] is our catalogue-side stand-in for that check.
bool isReactionEmoji(String value) =>
    isRenderableEmoji(stripEmojiPresentationSelectors(value));

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

/// U+200D. Legal Unicode, no glyph of its own.
const int _zwj = 0x200D;

/// U+FE0E. Text presentation selector.
const int _vs15 = 0xFE0E;

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
