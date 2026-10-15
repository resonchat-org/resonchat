import 'dart:io';

import 'package:libsignal/libsignal.dart';
import 'package:resonchat/crypto/libsignal_bootstrap.dart';

Future<void> main() async {
  await ensureLibSignal();
  final pair = KyberKeyPair.generate();
  final pub = pair.getPublicKey().serialize();
  final sk = pair.getSecretKey().serialize();
  stdout.writeln(
    'generate tag=0x${pub[0].toRadixString(16)} pub=${pub.length} sk=${sk.length}',
  );
  final roundTrip = KyberKeyPair.fromKeys(
    publicKey: KyberPublicKey.deserialize(bytes: pub),
    secretKey: KyberSecretKey.deserialize(bytes: sk),
  );
  stdout.writeln(
    'fromKeys ok tag=0x${roundTrip.getPublicKey().serialize()[0].toRadixString(16)}',
  );
  LibSignal.cleanup(dispose: true);
}
