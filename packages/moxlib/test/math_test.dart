import 'package:moxlib/moxlib.dart';
import 'package:test/test.dart';

void main() {
  group('implies', () {
    test('Truth table test', () {
      expect(implies(true, true), true);
      expect(implies(true, false), false);
      expect(implies(false, true), true);
      expect(implies(false, false), true);
    });
  });
}
