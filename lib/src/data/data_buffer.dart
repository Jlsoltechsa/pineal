import 'dart:typed_data';

/// Cache-friendly, GC-free storage for chart points.
///
/// Points live as an interleaved [Float32List] `[x0, y0, x1, y1, ...]`. This
/// avoids boxing each point as a Dart object and keeps the working set tight
/// enough for the CPU cache to stream through millions of samples without
/// stalling.
class DataBuffer {
  DataBuffer._(this._data, this.length, this.xSorted)
      : _xMin = _computeMin(_data, length, 0),
        _xMax = _computeMax(_data, length, 0),
        _yMin = _computeMin(_data, length, 1),
        _yMax = _computeMax(_data, length, 1);

  /// Builds a buffer from a flat `[x0, y0, x1, y1, ...]` list.
  factory DataBuffer.fromInterleaved(
    Float32List interleaved, {
    bool xSorted = true,
  }) {
    assert(interleaved.length.isEven, 'interleaved must have even length');
    return DataBuffer._(interleaved, interleaved.length >> 1, xSorted);
  }

  /// Builds a buffer from parallel `xs` and `ys` lists.
  factory DataBuffer.fromXY(List<double> xs, List<double> ys,
      {bool xSorted = true}) {
    assert(xs.length == ys.length, 'xs and ys must match in length');
    final data = Float32List(xs.length * 2);
    for (var i = 0; i < xs.length; i++) {
      final j = i << 1;
      data[j] = xs[i];
      data[j + 1] = ys[i];
    }
    return DataBuffer._(data, xs.length, xSorted);
  }

  /// Builds a buffer of `(index, value)` pairs — useful for line charts where
  /// the x dimension is just the sample number.
  factory DataBuffer.fromValues(List<double> values) {
    final data = Float32List(values.length * 2);
    for (var i = 0; i < values.length; i++) {
      final j = i << 1;
      data[j] = i.toDouble();
      data[j + 1] = values[i];
    }
    return DataBuffer._(data, values.length, true);
  }

  final Float32List _data;
  final int length;

  /// Whether x is monotonically non-decreasing. Enables O(log n) lookups.
  final bool xSorted;

  /// Bump this when mutating the underlying buffer in place so the
  /// [PictureCache] knows to invalidate. Replacing the buffer outright
  /// already invalidates via identity.
  int revision = 0;

  final double _xMin;
  final double _xMax;
  final double _yMin;
  final double _yMax;

  double get xMin => _xMin;
  double get xMax => _xMax;
  double get yMin => _yMin;
  double get yMax => _yMax;

  Float32List get raw => _data;

  double xAt(int i) => _data[i << 1];
  double yAt(int i) => _data[(i << 1) + 1];

  static double _computeMin(Float32List data, int n, int offset) {
    if (n == 0) return 0;
    var m = data[offset];
    for (var i = 1; i < n; i++) {
      final v = data[(i << 1) + offset];
      if (v < m) m = v;
    }
    return m;
  }

  static double _computeMax(Float32List data, int n, int offset) {
    if (n == 0) return 0;
    var m = data[offset];
    for (var i = 1; i < n; i++) {
      final v = data[(i << 1) + offset];
      if (v > m) m = v;
    }
    return m;
  }
}
