/// Represents an error related to Multi-User Chat (MUC).
abstract class MUCError {}

/// Error indicating an invalid (non-supported) stanza received while going
/// through normal operation/flow of an MUC.
class InvalidStanzaFormat extends MUCError {}

/// Represents an error indicating an abnormal condition while parsing
/// the DiscoInfo response stanza in Multi-User Chat (MUC).
class InvalidDiscoInfoResponse extends MUCError {}

/// Returned when no nickname was specified from the client side while trying to
/// perform some actions on the MUC, such as joining the room.
class NoNicknameSpecified extends MUCError {}

/// This error occurs when a user attempts to perform an action that requires
/// them to be a member of a room, but they are not currently joined to
/// that room.
class RoomNotJoinedError extends MUCError {}

/// Indicates that the MUC forbids us from joining, i.e. when we're banned.
class JoinForbiddenError extends MUCError {}

/// Indicates that an unspecific error occurred while joining.
class MUCUnspecificError extends MUCError {}

/// The room needs a password this client does not implement.
///
/// Its own type rather than [JoinForbiddenError], because "you are not allowed"
/// and "you need a password" need different sentences and one generic refusal
/// forces both into one.
class PasswordRequiredError implements MUCError {
  @override
  String toString() => 'the room requires a password';
}

/// The requested nickname is already in use.
class NicknameTakenError implements MUCError {
  @override
  String toString() => 'the nickname is already in use in this room';
}

/// This account is banned from the room.
class BannedFromRoomError implements MUCError {
  @override
  String toString() => 'this account is banned from the room';
}

/// The room is at its occupant limit.
class RoomFullError implements MUCError {
  @override
  String toString() => 'the room is full';
}

/// The service answered, but it does not have the room the client asked for.
///
/// Its own type because it is the one refusal where the *address* is the likely
/// mistake, and "could not join" sends the user looking for the wrong problem.
class RoomNotFoundError implements MUCError {
  @override
  String toString() => 'the service does not have that room';
}
