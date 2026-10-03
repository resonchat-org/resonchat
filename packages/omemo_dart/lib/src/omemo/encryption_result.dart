import 'package:meta/meta.dart';
import 'package:omemo_dart/src/omemo/encrypted_key.dart';
import 'package:omemo_dart/src/omemo/errors.dart';

@immutable
class EncryptionResult {
  const EncryptionResult(
    this.ciphertext,
    this.encryptedKeys,
    this.deviceEncryptionErrors,
    this.newRatchets,
    this.replacedRatchets,
    this.canSend,
  );

  /// The actual message that was encrypted.
  final List<int>? ciphertext;

  /// Mapping of the device Id to the key for decrypting ciphertext, encrypted
  /// for the ratchet with said device Id.
  final Map<String, List<EncryptedKey>> encryptedKeys;

  /// Mapping of a JID to
  final Map<String, List<EncryptToJidError>> deviceEncryptionErrors;

  /// Mapping of JIDs to a list of device ids for which we created a new ratchet session.
  final Map<String, List<int>> newRatchets;

  /// Similar to [newRatchets], but the ratchets listed in [replacedRatchets] where also existent before
  /// and replaced with the new ratchet.
  final Map<String, List<int>> replacedRatchets;

  /// A flag indicating that the message could be sent like that, i.e. every device
  /// we hold a bundle for was reached and no recipient was left partially
  /// encrypted.
  ///
  /// Not "at least one device per recipient". See [canSendAllDevicesReached] for
  /// why a partial result is worse than a refusal: it is undetectable from the
  /// sending side and is reported by the recipient as a broken client.
  final bool canSend;
}

/// Whether an outgoing stanza may be sent, given who it was addressed to, how
/// many devices each of them was reached on, and which devices recorded an error.
///
/// Split out of the manager so the rule can be stated once and tested directly.
/// It is the whole guarantee this package makes about an outgoing message, and a
/// rule that is only visible as an inline `.every(...)` at the bottom of a
/// hundred-line function is a rule that gets "simplified" back into the per-JID
/// form by the next person who does not know what it is for.
///
/// [recipientJids] is the expected set, not decoration. Every other argument is
/// a map that only ever gains entries for the recipients the loop actually
/// reached, so a JID that was never attempted is *absent* — and absent is
/// indistinguishable from zero to anything reading the result afterwards,
/// because the caller looks its errors up by key. Checking membership against
/// the intended set is the only way "this message was never addressed to anybody"
/// and "this message was addressed to somebody we never tried" both fail.
///
/// Three conditions, and all three are needed:
///
///  * [recipientJids] is **not empty**. `every` over an empty map is vacuously
///    true, so the encrypt-to-nobody case would otherwise pass both remaining
///    tests.
///  * every recipient in [recipientJids] is present in [successfulEncryptions]
///    with a count above zero, so neither a skipped recipient nor one with no
///    reachable device slips through.
///  * no device recorded an error, so one unreachable device out of forty is not
///    enough to pass.
///
/// Trust and enablement skips are deliberately *not* counted as errors: those are
/// decisions the user made about a named device, recorded in the trust store.
/// Only a device we tried to reach and could not appears in [encryptionErrors].
bool canSendAllDevicesReached(
  List<String> recipientJids,
  Map<String, int> successfulEncryptions,
  Map<String, List<EncryptToJidError>> encryptionErrors,
) =>
    recipientJids.isNotEmpty &&
    encryptionErrors.isEmpty &&
    recipientJids.every((jid) => (successfulEncryptions[jid] ?? 0) > 0);
