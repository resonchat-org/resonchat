/// The error conditions XEP-0060 and RFC 6120 define, kept apart because the
/// difference between them is what a caller needs in order to act.
///
/// The important one is [ItemNotFoundError] / [NodeNotFoundError]. Every other
/// error means "I do not know"; those two mean "I looked, and it is not there".
/// A caller that cannot tell those apart has to treat a device that no longer
/// exists the same as a network that hiccuped, and therefore has to leave both
/// alone — which is how a stale entry ends up staying forever.
abstract class PubSubError {}

/// The server answered with an error we do not recognise, or with none at all.
///
/// Deliberately the default: an unrecognised condition is not evidence of
/// anything, and code that treats it as "gone" is how a working device gets
/// deleted.
class UnknownPubSubError extends PubSubError {}

class PreconditionsNotMetError extends PubSubError {}

class MalformedResponseError extends PubSubError {}

/// The request succeeded but carried no item. Distinct from [ItemNotFoundError]
/// because some servers answer a missing item this way instead of with an
/// error, and both mean the same thing: it is not there.
class NoItemReturnedError extends PubSubError {}

/// `<item-not-found/>`: the node exists, the item does not.
class ItemNotFoundError extends PubSubError {}

/// `<node-not-found/>`: the node itself is gone. For a node we own, that means
/// it was deleted or never created.
class NodeNotFoundError extends PubSubError {}

/// `<forbidden/>`: we may not read this.
class ForbiddenError extends PubSubError {}

/// `<not-authorized/>`: authentication is required or insufficient.
class NotAuthorizedError extends PubSubError {}

/// `<service-unavailable/>`: the service is down, or the node is temporarily
/// unavailable. Explicitly *not* evidence that anything is gone.
class PubSubServiceUnavailableError extends PubSubError {}

/// `<not-allowed/>`: the change was refused.
class NotAllowedError extends PubSubError {}

/// `<not-subscribed/>`: we are not subscribed to this node.
class NotSubscribedError extends PubSubError {}

/// `<feature-not-implemented/>`: the server does not do this.
class FeatureNotImplementedError extends PubSubError {}

/// `<payment-required/>`.
class PaymentRequiredError extends PubSubError {}

/// `<registration-required/>`: an account is needed first.
class RegistrationRequiredError extends PubSubError {}

/// Returned if we can guess that the server, by which I mean ejabberd, rejected
/// the publish due to not liking that we set "max_items" to "max".
/// NOTE: This workaround is required due to https://github.com/processone/ejabberd/issues/3044
// TODO(Unknown): Remove once ejabberd fixes it
class EjabberdMaxItemsError extends PubSubError {}

/// True when this error positively establishes that something is not there.
///
/// The one question a caller pruning a device list needs answered, kept as a
/// named predicate so the answer has to be looked up rather than inferred from
/// the shape of an error type.
bool pubSubErrorMeansAbsent(PubSubError error) =>
    error is ItemNotFoundError ||
    error is NodeNotFoundError ||
    error is NoItemReturnedError;
