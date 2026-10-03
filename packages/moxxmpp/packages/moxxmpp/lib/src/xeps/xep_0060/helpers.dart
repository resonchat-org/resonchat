import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:moxxmpp/src/xeps/xep_0060/errors.dart';

/// Maps an IQ error stanza onto a [PubSubError].
///
/// The mapping covers the RFC 6120 and XEP-0060 conditions rather than the two
/// this function used to look for. That matters because the whole point of
/// having error *types* is to be able to act differently: `<item-not-found/>`
/// and `<service-unavailable/>` are both failures, and treating them alike means
/// a caller cannot prune a device that is gone without also pruning one whose
/// server was briefly down.
PubSubError getPubSubError(XMLNode stanza) {
  final error = stanza.firstTag('error');
  if (error != null) {
    final conflict = error.firstTag('conflict');
    final preconditions = error.firstTag('precondition-not-met');
    if (conflict != null && preconditions != null) {
      return PreconditionsNotMetError();
    }

    final badRequest = error.firstTag('bad-request', xmlns: fullStanzaXmlns);
    final text = error.firstTag('text', xmlns: fullStanzaXmlns);
    if (error.attributes['type'] == 'modify' &&
        badRequest != null &&
        text != null &&
        (text.text ?? '').contains('max_items')) {
      return EjabberdMaxItemsError();
    }

    // Order matters only in that the pubsub-specific conditions have to be
    // recognised before falling through to the generic stanza conditions.
    // `<item-not-found/>` appears both in RFC 6120 and in XEP-0060's condition
    // list, and either way it means the same thing here.
    if (error.firstTag('item-not-found') != null ||
        error.firstTag('item-not-found', xmlns: fullStanzaXmlns) != null) {
      return ItemNotFoundError();
    }
    if (error.firstTag('node-not-found') != null ||
        error.firstTag('node-not-found', xmlns: fullStanzaXmlns) != null) {
      return NodeNotFoundError();
    }
    if (error.firstTag('forbidden') != null) return ForbiddenError();
    if (error.firstTag('not-authorized') != null) {
      return NotAuthorizedError();
    }
    if (error.firstTag('service-unavailable') != null) {
      return PubSubServiceUnavailableError();
    }
    if (error.firstTag('not-allowed') != null) return NotAllowedError();
    if (error.firstTag('not-subscribed') != null) return NotSubscribedError();
    if (error.firstTag('feature-not-implemented') != null) {
      return FeatureNotImplementedError();
    }
    if (error.firstTag('payment-required') != null) {
      return PaymentRequiredError();
    }
    if (error.firstTag('registration-required') != null) {
      return RegistrationRequiredError();
    }
  }

  // An error we do not recognise is not evidence of anything, and must not be
  // reported as "gone".
  return UnknownPubSubError();
}
