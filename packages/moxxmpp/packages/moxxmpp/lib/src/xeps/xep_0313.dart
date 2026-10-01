import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/src/jid.dart';
import 'package:moxxmpp/src/managers/base.dart';
import 'package:moxxmpp/src/managers/data.dart';
import 'package:moxxmpp/src/managers/handlers.dart';
import 'package:moxxmpp/src/managers/namespaces.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stanza.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:moxxmpp/src/xeps/xep_0004.dart';
import 'package:moxxmpp/src/xeps/xep_0203.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

/// Logical XOR between [a] and [b].
// TODO(Unknown): Move to moxlib?
bool _xor(bool a, bool b) {
  return !a && b || a && !b;
}

abstract class MAMError {}

class UnknownMAMError extends MAMError {}

/// (The JID we sent the query to, the ID we used).
typedef PendingQueryKey = (JID, String);

class MAMData extends StanzaHandlerExtension {
  MAMData(this.queryId, this.delay);

  /// The id of the query.
  final String? queryId;

  /// The MAM-attached delayed delivery tag.
  final DelayedDeliveryData delay;
}

class MessageArchiveManagementManager extends XmppManagerBase {
  MessageArchiveManagementManager() : super(mamManager);

  /// Map for keeping track of pending queries. Query key -> Number of messages we received.
  final Map<PendingQueryKey, int> _pendingQueries = {};

  /// Lock for accessing [_pendingQueries].
  final Lock _lock = Lock();

  @override
  Future<bool> isSupported() async => true;

  @override
  List<StanzaHandler> getIncomingStanzaHandlers() => [
        StanzaHandler(
          stanzaTag: 'message',
          tagName: 'result',
          tagXmlns: mamXmlns,
          callback: _onMAMMessage,
          priority: -98,
        ),
      ];

  Future<StanzaHandlerData> _onMAMMessage(
    Stanza stanza,
    StanzaHandlerData data,
  ) async {
    if (stanza.from == null) {
      return data;
    }

    final result = stanza.firstTag('result', xmlns: mamXmlns)!;
    final qid = result.attributes['queryid']! as String;
    final jid = JID.fromString(stanza.from!);
    final key = (jid, qid);
    final isQuerying = await _lock.synchronized(() {
      final contains = _pendingQueries.containsKey(key);
      if (contains) {
        // Increment if the key exists.
        _pendingQueries[key] = _pendingQueries[key]! + 1;
      }

      return contains;
    });
    if (!isQuerying) {
      logger.warning('Received unexpected MAM result. Ignoring...');
      return StanzaHandlerData(true, true, stanza, data.extensions);
    }
    final forwarded = result.firstTag('forwarded', xmlns: forwardedXmlns)!;
    final message = forwarded.firstTag('message', xmlns: stanzaXmlns)!;
    final delay = forwarded.firstTag('delay', xmlns: delayedDeliveryXmlns)!;

    return StanzaHandlerData(
      false,
      false,
      Stanza.fromXMLNode(message),
      data.extensions
        ..set(
          MAMData(
            qid,
            DelayedDeliveryData(
              jid,
              DateTime.parse(delay.attributes['stamp']! as String),
            ),
          ),
        ),
    );
  }

  /// Query the MAM archive located at [archive].
  ///
  /// If [beforeId] is specified, then the
  /// query will try to query only messages that were sent before the stanza with id [beforeId].
  /// [afterId] works similary, but for specifies a lower (time) bound. Note that the archive
  /// must support "urn:xmpp:mam:2#extended", which this method does not check for. Cannot be specified
  /// with [ids].
  ///
  /// If [ids] is specified, then query only for those message ids. Cannot be specified with either [beforeId]
  /// or [afterId].
  ///
  /// If [pageSize] is specified, then the archive will return, at most, [pageSize] messages.
  ///
  /// Returns either a [MAMError], in case the request was unsuccessful, or the number of message
  /// stanzas we received from the query.
  Future<Result<MAMError, int>> requestMessages(
    JID archive, {
    String? beforeId,
    String? afterId,
    List<String>? ids,
    int? pageSize,
  }) async {
    assert(
      _xor(
        beforeId != null || afterId != null,
        ids != null,
      ),
      'beforeId/afterId cannot be specified with ids',
    );

    final uuid = const Uuid().v4();
    final key = (archive, uuid);
    await _lock.synchronized(() {
      _pendingQueries[key] = 0;
    });
    DataForm? dataForm;
    if (beforeId != null || afterId != null || ids != null) {
      dataForm = DataForm(
        type: 'submit',
        instructions: [],
        fields: [
          const DataFormField(
            varAttr: 'FORM_TYPE',
            type: 'hidden',
            options: [],
            values: [mamXmlns],
            isRequired: false,
          ),
          if (beforeId != null)
            DataFormField(
              varAttr: 'before-id',
              options: [],
              values: [beforeId],
              isRequired: false,
            ),
          if (afterId != null)
            DataFormField(
              varAttr: 'after-id',
              options: [],
              values: [afterId],
              isRequired: false,
            ),
          if (ids != null)
            DataFormField(
              varAttr: 'ids',
              options: [],
              values: ids,
              isRequired: false,
            ),
        ],
        reported: [],
        items: [],
      );
    }

    final request = Stanza.iq(
      type: 'set',
      to: archive.toString(),
      children: [
        XMLNode.xmlns(
          tag: 'query',
          xmlns: mamXmlns,
          attributes: {
            'queryid': uuid,
          },
          children: [
            if (pageSize != null)
              XMLNode.xmlns(
                tag: 'set',
                xmlns: rsmXmlns,
                children: [
                  XMLNode(
                    tag: 'max',
                    text: pageSize.toString(),
                  ),
                ],
              ),
            if (dataForm != null) dataForm.toXml(),
          ],
        ),
      ],
    );
    final result = await getAttributes().sendStanza(
      StanzaDetails(
        request,
        responseBypassesQueue: false,
      ),
    );

    // Remove the pending query key.
    final messageCount =
        await _lock.synchronized(() => _pendingQueries.remove(key));

    // Check if the query finished successfully
    if (result!.attributes['type'] != 'result') {
      return Result(UnknownMAMError());
    }
    return Result(messageCount);
  }
}
