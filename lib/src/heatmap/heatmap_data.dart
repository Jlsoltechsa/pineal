import 'dart:typed_data';

/// Row-major matrix of single-channel values.
///
/// Backed by a flat [Float32List] so a million-cell heatmap costs 4 MB and
/// streams through the CPU cache without any per-cell boxing.
class HeatmapData {
  HeatmapData._(this.values, this.width, this.height, this.minValue,
      this.maxValue);

  factory HeatmapData.from(Float32List values, int width, int height) {
    assert(values.length == width * height,
        'values length must equal width * height');
    var mn = double.infinity;
    var mx = -double.infinity;
    for (final v in values) {
      if (!v.isFinite) continue;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    if (!mn.isFinite || !mx.isFinite) {
      mn = 0;
      mx = 1;
    }
    return HeatmapData._(values, width, height, mn, mx);
  }

  /// Builds a `width × height` matrix from a generator. Convenience for
  /// quick demos; production paths should populate the [Float32List]
  /// directly to avoid the function-call overhead per cell.
  factory HeatmapData.generate(
    int width,
    int height,
    double Function(int x, int y) f,
  ) {
    final out = Float32List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        out[y * width + x] = f(x, y);
      }
    }
    return HeatmapData.from(out, width, height);
  }

  final Float32List values;
  final int width;
  final int height;
  final double minValue;
  final double maxValue;

  double valueAt(int x, int y) => values[y * width + x];
}
