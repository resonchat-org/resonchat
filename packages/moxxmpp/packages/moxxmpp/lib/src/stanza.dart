import 'package:moxxmpp/src/managers/data.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:moxxmpp/src/util/typed_map.dart';

/// A description of a stanza to send.
class StanzaDetails {
  const StanzaDetails(
    this.stanza, {
    this.extensions,
    this.addId = true,
    this.awaitable = true,
    this.shouldEncrypt = true,
    this.encrypted = false,
    this.forceEncryption = false,
    this.bypassQueue = false,
    this.responseBypassesQueue = true,
    this.postSendExtensions,
  });

  /// The stanza to send.
  final Stanza stanza;

  /// The extension data used for constructing the stanza.
  final TypedMap<StanzaHandlerExtension>? extensions;

  /// Flag indicating whether a stanza id should be added before sending.
  final bool addId;

  /// Track the stanza to allow awaiting its response.
  final bool awaitable;

  final bool forceEncryption;

  /// Flag indicating whether the stanza that is sent is already encrypted (true)
  /// or not (false). This is only useful for E2EE implementations that have to
  /// send heartbeats that must bypass themselves.
  final bool encrypted;

  /// Tells an E2EE implementation, if available, to encrypt the stanza (true) or
  /// ignore the stanza (false).
  final bool shouldEncrypt;

  /// Bypasses being put into the queue. Useful for sending stanzas that must go out
  /// now, where it's okay if it does not get sent.
  /// This should never have to be set to true.
  final bool bypassQueue;

  /// If the response is awaited, then prevent that response from bypassing the queue.
  final bool responseBypassesQueue;

  /// This makes the Stream Management implementation, when available, ignore the stanza,
  /// meaning that it gets counted but excluded from resending.
  /// This should never have to be set to true.
  final TypedMap<StanzaHandlerExtension>? postSendExtensions;
}

/// A general error type for errors.
abstract class StanzaError {
  static StanzaError? fromXMLNode(XMLNode node) {
    final error = node.firstTag('error');
    if (error == null) {
      return null;
    }

    final specificError = error.firstTagByXmlns(fullStanzaXmlns);
    if (specificError == null) {
      return UnknownStanzaError();
    }

    switch (specificError.tag) {
      case RemoteServerNotFoundError.tag:
        return RemoteServerNotFoundError();
      case RemoteServerTimeoutError.tag:
        return RemoteServerTimeoutError();
      case ServiceUnavailableError.tag:
        return ServiceUnavailableError();
    }

    // Keep the server's actual objection. Collapsing it into
    // UnknownStanzaError threw away the only useful part of the answer -
    // "not-authorized" and "service-unavailable" call for completely
    // different responses, and neither was visible before.
    return GenericStanzaError(
      type: '${error.attributes['type'] ?? ''}',
      code: '${error.attributes['code'] ?? ''}',
      text: error.firstTag('text')?.text ?? '',
      condition: specificError.tag,
    );
  }

  static StanzaError? fromStanza(Stanza stanza) {
    return fromXMLNode(stanza);
  }
}

/// An error condition this class does not model, with the server's own
/// wording preserved so callers can act on it.
class GenericStanzaError extends StanzaError {
  GenericStanzaError({
    required this.type,
    required this.code,
    required this.text,
    required this.condition,
  });

  /// RFC 6120 error type, e.g. `modify`, `cancel`, `auth`.
  final String type;

  /// Legacy error code, e.g. `404`.
  final String code;

  /// Human-readable text supplied by the server, if any.
  final String text;

  /// The defined condition's element name, e.g. `forbidden`.
  final String condition;

  @override
  String toString() => 'GenericStanzaError(type: $type, code: $code, '
      'condition: $condition${text.isEmpty ? '' : ', text: $text'})';
}

/// Recipient does not provide a given service.
/// https://xmpp.org/rfcs/rfc6120.html#stanzas-error-conditions-service-unavailable
class ServiceUnavailableError extends StanzaError {
  static const tag = 'service-unavailable';
}

/// Could not connect to the remote server.
/// https://xmpp.org/rfcs/rfc6120.html#stanzas-error-conditions-remote-server-not-found
class RemoteServerNotFoundError extends StanzaError {
  static const tag = 'remote-server-not-found';
}

/// The connection to the remote server timed out.
/// https://xmpp.org/rfcs/rfc6120.html#stanzas-error-conditions-remote-server-timeout
class RemoteServerTimeoutError extends StanzaError {
  static const tag = 'remote-server-timeout';
}

/// An unknown error.
class UnknownStanzaError extends StanzaError {}

const _stanzaNotDefined = Object();

class Stanza extends XMLNode {
  // ignore: use_super_parameters
  Stanza({
    this.to,
    this.from,
    this.type,
    this.id,
    List<XMLNode> children = const [],
    required String tag,
    Map<String, String> attributes = const {},
    String? xmlns,
  }) : super(
          tag: tag,
          attributes: <String, dynamic>{
            ...attributes,
            ...type != null
                ? <String, dynamic>{'type': type}
                : <String, dynamic>{},
            ...id != null ? <String, dynamic>{'id': id} : <String, dynamic>{},
            ...to != null ? <String, dynamic>{'to': to} : <String, dynamic>{},
            ...from != null
                ? <String, dynamic>{'from': from}
                : <String, dynamic>{},
            if (xmlns != null) 'xmlns': xmlns,
          },
          children: children,
        );

  factory Stanza.iq({
    String? to,
    String? from,
    String? type,
    String? id,
    List<XMLNode> children = const [],
    Map<String, String>? attributes = const {},
    String? xmlns,
  }) {
    return Stanza(
      tag: 'iq',
      from: from,
      to: to,
      id: id,
      type: type,
      attributes: <String, String>{...attributes!},
      children: children,
      xmlns: xmlns,
    );
  }

  factory Stanza.presence({
    String? to,
    String? from,
    String? type,
    String? id,
    List<XMLNode> children = const [],
    Map<String, String>? attributes = const {},
    String? xmlns,
  }) {
    return Stanza(
      tag: 'presence',
      from: from,
      to: to,
      id: id,
      type: type,
      attributes: <String, String>{...attributes!},
      children: children,
      xmlns: xmlns,
    );
  }
  factory Stanza.message({
    String? to,
    String? from,
    String? type,
    String? id,
    List<XMLNode> children = const [],
    Map<String, String>? attributes = const {},
    String? xmlns,
  }) {
    return Stanza(
      tag: 'message',
      from: from,
      to: to,
      id: id,
      type: type,
      attributes: <String, String>{...attributes!},
      children: children,
      xmlns: xmlns,
    );
  }

  factory Stanza.fromXMLNode(XMLNode node) {
    return Stanza(
      to: node.attributes['to'] as String?,
      from: node.attributes['from'] as String?,
      id: node.attributes['id'] as String?,
      tag: node.tag,
      type: node.attributes['type'] as String?,
      children: node.children,
      // TODO(Unknown): Remove to, from, id, and type
      // TODO(Unknown): Not sure if this is the correct way to approach this
      attributes:
          node.attributes.map<String, String>((String key, dynamic value) {
        return MapEntry(key, value.toString());
      }),
    );
  }

  String? to;
  String? from;
  String? type;
  String? id;

  Stanza copyWith({
    String? id,
    Object? from = _stanzaNotDefined,
    String? to,
    String? type,
    List<XMLNode>? children,
    String? xmlns,
  }) {
    return Stanza(
      tag: tag,
      to: to ?? this.to,
      from: from != _stanzaNotDefined ? from as String? : this.from,
      id: id ?? this.id,
      type: type ?? this.type,
      children: children ?? this.children,
      attributes: {
        ...attributes.cast<String, String>(),
      },
      xmlns: xmlns ?? this.xmlns,
    );
  }
}

/// Build an <error /> element with a child <[condition] type="[type]" />. If [text]
/// is not null, then the condition element will contain a <text /> element with [text]
/// as the body.
XMLNode buildErrorElement(String type, String condition, {String? text}) {
  return XMLNode(
    tag: 'error',
    attributes: <String, dynamic>{'type': type},
    children: [
      XMLNode.xmlns(
        tag: condition,
        xmlns: fullStanzaXmlns,
        children: [
          if (text != null)
            XMLNode.xmlns(
              tag: 'text',
              xmlns: fullStanzaXmlns,
              text: text,
            ),
        ],
      ),
    ],
  );
}
