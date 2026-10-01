/// Holds a value of either [T] or [V].
class Result<T, V> {
  /// Constructs a result. [_data] must be either of type [T] or [V].
  const Result(this._data)
      : assert(
          _data is T || _data is V,
          'Invalid data type $_data: Must be either $T or $V',
        );
  final dynamic _data;

  /// Returns true if the data contained within is of type [S]. If not, returns false.
  bool isType<S>() => _data is S;

  /// Returns the data contained within cast to [S]. Before doing this call, it's recommended
  /// to check isType<S>() first.
  S get<S>() {
    assert(_data is S, 'Data is not $S');

    return _data as S;
  }

  /// Returns the runtime type of the data.
  Object get dataRuntimeType => _data.runtimeType;
}
