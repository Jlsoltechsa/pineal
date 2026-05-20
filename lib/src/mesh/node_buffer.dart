import 'dart:typed_data';

/// Cache-friendly storage for graph nodes.
///
/// Layout in memory is `[x0, y0, r0, x1, y1, r1, …]`. Position and radius
/// live in the same buffer so a Barnes-Hut iteration over the dataset
/// streams in 12 bytes per node — fits easily in L1 even for huge graphs.
class NodeBuffer {
  NodeBuffer._(this._data, this.length);

  factory NodeBuffer.empty(int count, {double radius = 8}) {
    final data = Float32List(count * _stride);
    for (var i = 0; i < count; i++) {
      data[i * _stride + 2] = radius;
    }
    return NodeBuffer._(data, count);
  }

  /// Wraps an already-allocated interleaved buffer. Used by the isolate
  /// worker which receives the raw Float32List across the port boundary.
  factory NodeBuffer.wrap(Float32List raw, int length) {
    assert(raw.length >= length * _stride, 'raw buffer too small');
    return NodeBuffer._(raw, length);
  }

  factory NodeBuffer.fromXY(List<double> xs, List<double> ys,
      {List<double>? radii, double defaultRadius = 8}) {
    assert(xs.length == ys.length);
    final data = Float32List(xs.length * _stride);
    for (var i = 0; i < xs.length; i++) {
      final off = i * _stride;
      data[off] = xs[i];
      data[off + 1] = ys[i];
      data[off + 2] = radii != null ? radii[i] : defaultRadius;
    }
    return NodeBuffer._(data, xs.length);
  }

  static const int _stride = 3;

  final Float32List _data;
  final int length;

  /// Bump after mutating in place so renderers know to discard their caches.
  int revision = 0;

  Float32List get raw => _data;

  double x(int i) => _data[i * _stride];
  double y(int i) => _data[i * _stride + 1];
  double r(int i) => _data[i * _stride + 2];

  void setX(int i, double v) => _data[i * _stride] = v;
  void setY(int i, double v) => _data[i * _stride + 1] = v;
  void setR(int i, double v) => _data[i * _stride + 2] = v;

  void setXY(int i, double xv, double yv) {
    final o = i * _stride;
    _data[o] = xv;
    _data[o + 1] = yv;
  }

  /// Axis-aligned bounding box across every node, padded by node radius.
  ({double xMin, double yMin, double xMax, double yMax}) bounds() {
    if (length == 0) return (xMin: 0, yMin: 0, xMax: 1, yMax: 1);
    var xMin = double.infinity,
        yMin = double.infinity,
        xMax = -double.infinity,
        yMax = -double.infinity;
    for (var i = 0; i < length; i++) {
      final px = x(i), py = y(i), pr = r(i);
      if (px - pr < xMin) xMin = px - pr;
      if (px + pr > xMax) xMax = px + pr;
      if (py - pr < yMin) yMin = py - pr;
      if (py + pr > yMax) yMax = py + pr;
    }
    return (xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax);
  }
}
