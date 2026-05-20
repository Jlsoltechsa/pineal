import 'dart:typed_data';

/// Storage for OHLC bars (and optional volume).
///
/// Layout per bar: `[t, o, h, l, c, v]` — 6 floats. Volume is optional;
/// pass `0` when unavailable. Keeping the whole series in one [Float32List]
/// matches the access pattern of the renderer (sequential by time) and the
/// downsampler (sequential aggregation).
class OhlcBuffer {
  OhlcBuffer._(this._data, this.length, this.xMin, this.xMax);

  factory OhlcBuffer.fromInterleaved(Float32List interleaved) {
    assert(interleaved.length % 6 == 0,
        'OHLC buffer must be a multiple of 6 floats');
    final n = interleaved.length ~/ 6;
    final xMin = n == 0 ? 0.0 : interleaved[0];
    final xMax = n == 0 ? 1.0 : interleaved[(n - 1) * 6];
    return OhlcBuffer._(interleaved, n, xMin, xMax);
  }

  /// Convenience builder from parallel lists. All inputs must have the
  /// same length.
  factory OhlcBuffer.fromOHLC({
    required List<double> t,
    required List<double> open,
    required List<double> high,
    required List<double> low,
    required List<double> close,
    List<double>? volume,
  }) {
    assert(t.length == open.length &&
        open.length == high.length &&
        high.length == low.length &&
        low.length == close.length);
    final n = t.length;
    final data = Float32List(n * 6);
    for (var i = 0; i < n; i++) {
      final o = i * 6;
      data[o] = t[i];
      data[o + 1] = open[i];
      data[o + 2] = high[i];
      data[o + 3] = low[i];
      data[o + 4] = close[i];
      data[o + 5] = volume == null ? 0 : volume[i];
    }
    return OhlcBuffer._(
        data, n, t.isEmpty ? 0 : t.first, t.isEmpty ? 1 : t.last);
  }

  final Float32List _data;
  final int length;
  final double xMin;
  final double xMax;
  int revision = 0;

  Float32List get raw => _data;

  double t(int i) => _data[i * 6];
  double open(int i) => _data[i * 6 + 1];
  double high(int i) => _data[i * 6 + 2];
  double low(int i) => _data[i * 6 + 3];
  double close(int i) => _data[i * 6 + 4];
  double volume(int i) => _data[i * 6 + 5];

  /// Returns global `[yMin, yMax]` across high/low. Useful for auto-fit.
  ({double yMin, double yMax}) priceBounds() {
    if (length == 0) return (yMin: 0, yMax: 1);
    var mn = double.infinity, mx = -double.infinity;
    for (var i = 0; i < length; i++) {
      final lo = low(i);
      final hi = high(i);
      if (lo < mn) mn = lo;
      if (hi > mx) mx = hi;
    }
    return (yMin: mn, yMax: mx);
  }

  /// Binary search of the bar whose `t` is `>= target`. Returns length when
  /// nothing matches. Assumes ascending time order.
  int lowerBound(double target) {
    var lo = 0;
    var hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (t(mid) < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
