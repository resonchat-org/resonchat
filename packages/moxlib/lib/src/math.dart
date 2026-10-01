/// A mathematical implication between [a] and [b] (a -> b);
bool implies(bool a, bool b) {
  return !a || b;
}
