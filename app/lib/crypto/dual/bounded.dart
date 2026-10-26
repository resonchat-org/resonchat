// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bounded concurrency, as a value.
//
// Why this is its own file and not a private helper: a concurrency primitive is
// where a bug hides *quietly*. A too-low limit is slow, a too-high limit is rude,
// and one that leaks a rejection takes down the batch that was merely waiting on
// it — none of which announce themselves. Being unable to name it from a test is
// what makes those failures permanent rather than transient.

/// Runs [action] over every element of [items], at most [limit] at a time.
///
/// For work whose results are unioned rather than ordered: completion order is
/// whatever order the futures finish in, so a caller that needs its results in
/// input order must sort them itself. That restriction is the reason this does
/// not return a list — a returned list would invite a caller to believe in an
/// order it does not have.
///
/// An exception from one element does not cancel the rest. The use this was
/// written for is fetching one peer's device bundles, where one unreadable
/// bundle is a normal thing that happens and the other thirty-nine devices are
/// still perfectly reachable. Letting a single rejection propagate would
/// discard every device that had already answered, which is a strictly worse
/// outcome than losing the one that failed.
///
/// [limit] below one is treated as one. A zero or negative cap with the obvious
/// implementation deadlocks or silently drops everything, and neither is worth
/// the flexibility.
Future<void> forEachBounded<T>(
  Iterable<T> items,
  int limit,
  Future<void> Function(T) action,
) async {
  final width = limit < 1 ? 1 : limit;
  final pending = <Future<void>>[];
  for (final item in items) {
    while (pending.length >= width) {
      await pending.removeAt(0);
    }
    // The catch is inside the future on purpose. Putting it here rather than at
    // the `await` below is what makes `await pending.removeAt(0)` incapable of
    // throwing, and therefore what stops one failure from becoming a batch
    // failure.
    pending.add(action(item).catchError((Object _) {}));
  }
  await Future.wait(pending);
}

/// The largest number of [items] that were ever in flight at once, running the
/// same [limit] the caller would use.
///
/// Exposed for tests, and for the one caller that needs to justify its limit.
///
/// [limit] is a parameter rather than being pinned wide on purpose. Pinned wide,
/// this would run everything at once and report the *runner's* natural
/// concurrency rather than the concurrency the caller asked for — which is
/// exactly the number a test of the limit needs to check, so a pinned-wide
/// version cannot fail when the limit stops working. A measurement that cannot
/// detect the bug it exists to detect is worse than none, because it reads as
/// evidence.
Future<int> measurePeakConcurrency<T>(
  Iterable<T> items,
  int limit,
  Future<void> Function(T) action,
) async {
  var live = 0;
  var peak = 0;
  await forEachBounded(items, limit, (item) async {
    live++;
    if (live > peak) peak = live;
    try {
      await action(item);
    } finally {
      live--;
    }
  });
  return peak;
}
