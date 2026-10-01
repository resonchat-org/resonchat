import 'dart:async';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

/// Interface to allow arbitrary data to be sent as long as it can be
/// JSON serialized/deserialized.
class JsonImplementation {
  JsonImplementation();

  // ignore: avoid_unused_constructor_parameters
  factory JsonImplementation.fromJson(Map<String, dynamic> json) {
    return JsonImplementation();
  }

  Map<String, dynamic> toJson() => {};
}

/// Wrapper class that adds an ID to the data packet to be sent.
class DataWrapper<T extends JsonImplementation> {
  const DataWrapper(
    this.id,
    this.data,
  );

  /// The id of the data packet.
  final String id;

  /// The actual data.
  final T data;

  Map<String, dynamic> toJson() => {'id': id, 'data': data.toJson()};

  static DataWrapper fromJson<T extends JsonImplementation>(
    Map<String, dynamic> json,
  ) =>
      DataWrapper<T>(
        json['id']! as String,
        json['data']! as T,
      );

  DataWrapper reply(T newData) => DataWrapper(id, newData);
}

/// This class is useful in contexts where data is sent between two parties, e.g. the
/// UI and the background service and a correlation between requests and responses is
/// to be enabled.
///
/// awaiting [sendData] will return a [Future] that will resolve to the reresponse when
/// received via [onData].
abstract class AwaitableDataSender<S extends JsonImplementation,
    R extends JsonImplementation> {
  @mustCallSuper
  AwaitableDataSender();

  /// A mapping of ID to completer for pending requests.
  final Map<String, Completer<R>> _awaitables = {};

  /// Critical section for accessing [AwaitableDataSender._awaitables].
  final Lock _lock = Lock();

  /// A UUID object for generating UUIDs.
  final Uuid _uuid = const Uuid();

  /// A logger.
  final Logger _log = Logger('AwaitableDataSender');

  @visibleForTesting
  Map<String, Completer<R>> getAwaitables() => _awaitables;

  /// Called after an awaitable has been added.
  @visibleForTesting
  void onAdd() {}

  /// NOTE: Must be overwritten by the actual implementation
  @visibleForOverriding
  Future<void> sendDataImpl(DataWrapper data);

  /// Sends [data] using [sendDataImpl]. If [awaitable] is true, then a
  /// Future will be returned that can be used to await a response. If it
  /// is false, then null will be imediately resolved.
  Future<R?> sendData(
    S data, {
    bool awaitable = true,
    @visibleForTesting String? id,
  }) async {
    // ignore: no_leading_underscores_for_local_identifiers
    final _id = id ?? _uuid.v4();
    var future = Future<R?>.value();
    _log.fine('sendData: Waiting to acquire lock...');
    await _lock.synchronized(() async {
      _log.fine('sendData: Done');
      if (awaitable) {
        _awaitables[_id] = Completer();
        onAdd();
      }

      await sendDataImpl(
        DataWrapper<S>(
          _id,
          data,
        ),
      );

      if (awaitable) {
        future = _awaitables[_id]!.future;
      }

      _log.fine('sendData: Releasing lock...');
    });

    return future;
  }

  /// Should be called when a [DataWrapper] has been received. Will resolve
  /// the promise received from [sendData].
  Future<bool> onData(DataWrapper<R> data) async {
    _log.fine('onData: Waiting to acquire lock...');
    final completer = await _lock.synchronized(() async {
      _log.fine('onData: Done');
      final c = _awaitables[data.id];
      if (c != null) {
        _awaitables.remove(data.id);
        return c;
      }

      _log.fine('onData: Releasing lock');
      return null;
    });

    completer?.complete(data.data);

    return completer != null;
  }
}
