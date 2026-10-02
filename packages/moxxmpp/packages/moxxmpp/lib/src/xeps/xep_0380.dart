import 'package:moxxmpp/src/managers/base.dart';
import 'package:moxxmpp/src/managers/data.dart';
import 'package:moxxmpp/src/managers/handlers.dart';
import 'package:moxxmpp/src/managers/namespaces.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stanza.dart';
import 'package:moxxmpp/src/stringxml.dart';

enum ExplicitEncryptionType implements StanzaHandlerExtension {
  otr,
  legacyOpenPGP,
  openPGP,
  omemo,
  omemo1,
  omemo2,

  /// The post-quantum track of resonchat (`urn:xmpp:pomemo:0`).
  ///
  /// Added here rather than in application code so the value travels through
  /// the same extension mechanism as every other encryption type: the label
  /// under a message has to be derivable from the wire on both ends.
  pomemo0,
  unknown;

  factory ExplicitEncryptionType.fromNamespace(String namespace) {
    switch (namespace) {
      case emeOtr:
        return ExplicitEncryptionType.otr;
      case emeLegacyOpenPGP:
        return ExplicitEncryptionType.legacyOpenPGP;
      case emeOpenPGP:
        return ExplicitEncryptionType.openPGP;
      case emeOmemo:
        return ExplicitEncryptionType.omemo;
      case emeOmemo1:
        return ExplicitEncryptionType.omemo1;
      case emeOmemo2:
        return ExplicitEncryptionType.omemo2;
      case emePomemo0:
        return ExplicitEncryptionType.pomemo0;
      default:
        return ExplicitEncryptionType.unknown;
    }
  }

  String toNamespace() {
    switch (this) {
      case ExplicitEncryptionType.otr:
        return emeOtr;
      case ExplicitEncryptionType.legacyOpenPGP:
        return emeLegacyOpenPGP;
      case ExplicitEncryptionType.openPGP:
        return emeOpenPGP;
      case ExplicitEncryptionType.omemo:
        return emeOmemo;
      case ExplicitEncryptionType.omemo1:
        return emeOmemo1;
      case ExplicitEncryptionType.omemo2:
        return emeOmemo2;
      case ExplicitEncryptionType.pomemo0:
        return emePomemo0;
      case ExplicitEncryptionType.unknown:
        return '';
    }
  }

  /// Create an <encryption /> element with an xmlns indicating what type of encryption was
  /// used.
  ///
  /// XEP-0380 also defines an optional `name` attribute for a human-readable
  /// label. Without it, a peer that does not know the namespace has nothing to
  /// show, and ours falls back to whatever the client happens to guess.
  XMLNode toXML({String? name}) {
    return XMLNode.xmlns(
      tag: 'encryption',
      xmlns: emeXmlns,
      attributes: <String, String>{
        'namespace': toNamespace(),
        if (name != null && name.isNotEmpty) 'name': name,
      },
    );
  }
}

class EmeManager extends XmppManagerBase {
  EmeManager() : super(emeManager);
  @override
  Future<bool> isSupported() async => true;

  @override
  List<String> getDiscoFeatures() => [emeXmlns];

  @override
  List<StanzaHandler> getIncomingStanzaHandlers() => [
        StanzaHandler(
          tagName: 'encryption',
          tagXmlns: emeXmlns,
          callback: _onStanzaReceived,
          // Before the message handler
          priority: -99,
        ),
      ];

  Future<StanzaHandlerData> _onStanzaReceived(
    Stanza message,
    StanzaHandlerData state,
  ) async {
    // Defensive: this handler only fires when an <encryption> child matched,
    // but an unguarded dereference here would take down the connection
    // handler over a cosmetic element. The same pattern has twice caused a
    // crash elsewhere in this library.
    final encryption = message.firstTag('encryption', xmlns: emeXmlns);
    if (encryption == null) return state;

    final namespace = encryption.attributes['namespace'];
    if (namespace == null || namespace.isEmpty) return state;

    return state
      ..extensions.set(ExplicitEncryptionType.fromNamespace(namespace));
  }
}
