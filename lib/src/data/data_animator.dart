import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

/// Tweens between two interleaved `[x0,y0,...]` snapshots.
///
/// Animation runs over the *summarized* vertex set, not the raw buffer, so
/// the per-frame cost stays at O(verticesOnScreen) regardless of how big the
/// underlying dataset is.
class DataAnimator extends ChangeNotifier {
  DataAnimator({
    required TickerProvider vsync,
    required Float32List initial,
    Duration duration = const Duration(milliseconds: 350),
    Curve curve = Curves.easeOutCubic,
  })  : _from = Float32List.fromList(initial),
        _to = Float32List.fromList(initial),
        _out = Float32List.fromList(initial),
        _curve = curve,
        _controller = AnimationController(vsync: vsync, duration: duration) {
    _controller.addListener(_onTick);
  }

  Float32List _from;
  Float32List _to;
  Float32List _out;
  Curve _curve;
  final AnimationController _controller;

  /// Latest interpolated snapshot. Same instance frame-to-frame to keep the
  /// allocator quiet; consumers must not retain references across frames.
  Float32List get current => _out;

  bool get isAnimating => _controller.isAnimating;

  /// Starts a transition to [target]. If the lengths differ we resample
  /// [target] by stretched index lookup — assumes the caller summarized both
  /// snapshots through the same width, so the mismatch is at most one vertex.
  void transitionTo(
    Float32List target, {
    Duration? duration,
    Curve? curve,
  }) {
    if (duration != null) _controller.duration = duration;
    if (curve != null) _curve = curve;

    // Freeze the current interpolated state as the new starting point.
    _from = Float32List.fromList(_out);
    _to = _matchLength(target, _from.length);

    _controller
      ..stop()
      ..value = 0.0
      ..forward();
  }

  void snapTo(Float32List target) {
    _controller.stop();
    _from = Float32List.fromList(target);
    _to = Float32List.fromList(target);
    _out = Float32List.fromList(target);
    notifyListeners();
  }

  void _onTick() {
    final t = _curve.transform(_controller.value);
    final n = _from.length;
    if (_out.length != n) _out = Float32List(n);
    for (var i = 0; i < n; i++) {
      _out[i] = _from[i] + (_to[i] - _from[i]) * t;
    }
    notifyListeners();
  }

  Float32List _matchLength(Float32List src, int targetVertexFloats) {
    if (src.length == targetVertexFloats) return Float32List.fromList(src);
    final out = Float32List(targetVertexFloats);
    final srcPairs = src.length >> 1;
    final dstPairs = targetVertexFloats >> 1;
    if (srcPairs < 2) {
      // Degenerate — fill with first vertex.
      final x = src.isNotEmpty ? src[0] : 0.0;
      final y = src.length > 1 ? src[1] : 0.0;
      for (var i = 0; i < dstPairs; i++) {
        out[i * 2] = x;
        out[i * 2 + 1] = y;
      }
      return out;
    }
    for (var k = 0; k < dstPairs; k++) {
      final pos = (k * (srcPairs - 1)) / (dstPairs - 1);
      final lo = pos.floor();
      final hi = lo + 1 < srcPairs ? lo + 1 : lo;
      final f = pos - lo;
      out[k * 2] = src[lo * 2] + (src[hi * 2] - src[lo * 2]) * f;
      out[k * 2 + 1] = src[lo * 2 + 1] + (src[hi * 2 + 1] - src[lo * 2 + 1]) * f;
    }
    return out;
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }
}
