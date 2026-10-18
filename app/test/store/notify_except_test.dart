// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';
import 'package:resonchat/store/chat_notify_mode.dart';

void main() {
  test('a real JID matches, and a nick matches only its nick key', () {
    const except = ['alice@example.org', 'nick:bob'];
    expect(
      senderIsNotifyExcept(
        except: except,
        nick: 'alice',
        realJid: 'Alice@Example.org',
      ),
      isTrue,
    );
    expect(
      senderIsNotifyExcept(except: except, nick: 'bob', realJid: null),
      isTrue,
    );
    expect(
      senderIsNotifyExcept(
        except: except,
        nick: 'carol',
        realJid: 'carol@example.org',
      ),
      isFalse,
    );
  });

  test('a broken stored list is empty', () {
    expect(decodeNotifyExcept(''), isEmpty);
    expect(decodeNotifyExcept('not-json'), isEmpty);
    expect(decodeNotifyExcept('["a"]'), ['a']);
  });
}
