import 'dart:math' as math;
import 'dart:ui';

/// Polar projection: `(angle in radians, radius in normalized 0..1)` →
/// pixel offset inside [bounds].
///
/// Angle convention: `0` points up (north), increasing clockwise. Matches the
/// expectation of pie/donut charts and radar axes labelled clockwise.
class PolarCoordinates {
  PolarCoordinates({
    required this.bounds,
    this.startAngle = -math.pi / 2,
    this.clockwise = true,
  });

  final Rect bounds;
  final double startAngle;
  final bool clockwise;

  Offset get center => bounds.center;
  double get maxRadius => bounds.shortestSide * 0.5;

  /// Projects `(angle, normalizedRadius)` where `normalizedRadius ∈ [0,1]`.
  Offset project(double angle, double normalizedRadius) {
    final r = normalizedRadius * maxRadius;
    final a = clockwise ? startAngle + angle : startAngle - angle;
    return Offset(center.dx + math.cos(a) * r, center.dy + math.sin(a) * r);
  }

  /// Hit-test a pixel against a sector defined by `[a0, a1]` and a
  /// radial band `[r0, r1]` (both in the same conventions as [project]).
  bool hitSector(Offset pixel, double a0, double a1, double r0, double r1) {
    final dx = pixel.dx - center.dx;
    final dy = pixel.dy - center.dy;
    final r = math.sqrt(dx * dx + dy * dy);
    if (r < r0 * maxRadius || r > r1 * maxRadius) return false;
    var theta = math.atan2(dy, dx) - startAngle;
    if (!clockwise) theta = -theta;
    theta = theta % (2 * math.pi);
    if (theta < 0) theta += 2 * math.pi;
    final start = a0 % (2 * math.pi);
    final end = a1 % (2 * math.pi);
    if (start <= end) {
      return theta >= start && theta <= end;
    }
    return theta >= start || theta <= end;
  }
}
