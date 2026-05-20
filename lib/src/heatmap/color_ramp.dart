import 'dart:typed_data';
import 'dart:ui';

/// Gradient defined by stops in `[0, 1]`. Lookup is `O(log n)` via a small
/// precomputed table, so encoding 1M cells stays in the millisecond range.
class ColorRamp {
  ColorRamp(List<({double t, Color color})> stops, {int tableSize = 256})
      : assert(stops.length >= 2, 'need at least two stops') {
    final sorted = [...stops]..sort((a, b) => a.t.compareTo(b.t));
    _table = Uint8List(tableSize * 4);
    for (var i = 0; i < tableSize; i++) {
      final t = i / (tableSize - 1);
      final c = _interpolate(sorted, t);
      _table[i * 4] = c.r.toInt();
      _table[i * 4 + 1] = c.g.toInt();
      _table[i * 4 + 2] = c.b.toInt();
      _table[i * 4 + 3] = c.a.toInt();
    }
    _size = tableSize;
  }

  /// Built-in: blue → cyan → green → yellow → red. The default for density
  /// maps; perceptually balanced enough for most uses without bringing in a
  /// CIELAB-aware ramp generator.
  factory ColorRamp.heat() => ColorRamp(const [
        (t: 0.0, color: Color(0xFF0D1B2A)),
        (t: 0.25, color: Color(0xFF1E88E5)),
        (t: 0.5, color: Color(0xFF66BB6A)),
        (t: 0.75, color: Color(0xFFFFCA28)),
        (t: 1.0, color: Color(0xFFEF5350)),
      ]);

  factory ColorRamp.viridis() => ColorRamp(const [
        (t: 0.0, color: Color(0xFF440154)),
        (t: 0.25, color: Color(0xFF3B528B)),
        (t: 0.5, color: Color(0xFF21908C)),
        (t: 0.75, color: Color(0xFF5DC863)),
        (t: 1.0, color: Color(0xFFFDE725)),
      ]);

  factory ColorRamp.greyscale() => ColorRamp(const [
        (t: 0.0, color: Color(0xFF000000)),
        (t: 1.0, color: Color(0xFFFFFFFF)),
      ]);

  late final Uint8List _table;
  late final int _size;

  /// Precomputed LUT (RGBA bytes, `tableSize * 4` long). Exposed so encoders
  /// running on a worker isolate can ship a stable copy without pulling
  /// closures across the SendPort.
  Uint8List get table => _table;
  int get tableSize => _size;

  /// RGBA bytes (straight, not premultiplied) for `t ∈ [0, 1]`.
  /// Writes into [out] at [offset].
  void writeAt(double t, Uint8List out, int offset) {
    if (!t.isFinite) {
      out[offset] = 0;
      out[offset + 1] = 0;
      out[offset + 2] = 0;
      out[offset + 3] = 0;
      return;
    }
    final clamped = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    final idx = (clamped * (_size - 1)).floor() * 4;
    out[offset] = _table[idx];
    out[offset + 1] = _table[idx + 1];
    out[offset + 2] = _table[idx + 2];
    out[offset + 3] = _table[idx + 3];
  }

  static _RGBA _interpolate(
      List<({double t, Color color})> stops, double t) {
    if (t <= stops.first.t) return _RGBA.of(stops.first.color);
    if (t >= stops.last.t) return _RGBA.of(stops.last.color);
    for (var i = 1; i < stops.length; i++) {
      if (t <= stops[i].t) {
        final a = stops[i - 1];
        final b = stops[i];
        final span = b.t - a.t;
        final local = span == 0 ? 0.0 : (t - a.t) / span;
        return _RGBA.lerp(_RGBA.of(a.color), _RGBA.of(b.color), local);
      }
    }
    return _RGBA.of(stops.last.color);
  }
}

class _RGBA {
  _RGBA(this.r, this.g, this.b, this.a);
  factory _RGBA.of(Color c) {
    final v = c.toARGB32();
    return _RGBA(
      ((v >> 16) & 0xFF).toDouble(),
      ((v >> 8) & 0xFF).toDouble(),
      (v & 0xFF).toDouble(),
      ((v >> 24) & 0xFF).toDouble(),
    );
  }
  static _RGBA lerp(_RGBA a, _RGBA b, double t) => _RGBA(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        a.a + (b.a - a.a) * t,
      );
  final double r, g, b, a;
}
