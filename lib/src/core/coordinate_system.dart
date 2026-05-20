import 'dart:math' as math;
import 'dart:ui';

/// Maps a data-space value into the unit interval `[0, 1]` and back.
///
/// Implementations are intentionally cheap to copy — they are recomputed
/// every frame as the viewport mutates.
abstract class Scale {
  const Scale(this.domainMin, this.domainMax);
  final double domainMin;
  final double domainMax;

  double normalize(double value);
  double invert(double t);

  Scale withDomain(double min, double max);
}

class LinearScale extends Scale {
  const LinearScale(super.domainMin, super.domainMax);

  @override
  double normalize(double value) {
    final span = domainMax - domainMin;
    if (span == 0) return 0;
    return (value - domainMin) / span;
  }

  @override
  double invert(double t) => domainMin + t * (domainMax - domainMin);

  @override
  LinearScale withDomain(double min, double max) => LinearScale(min, max);
}

/// Base-10 log scale. Domain must be strictly positive.
class LogScale extends Scale {
  LogScale(super.domainMin, super.domainMax)
      : assert(domainMin > 0 && domainMax > 0, 'log domain must be positive'),
        _logMin = math.log(domainMin) / math.ln10,
        _logMax = math.log(domainMax) / math.ln10;

  final double _logMin;
  final double _logMax;

  @override
  double normalize(double value) {
    final span = _logMax - _logMin;
    if (span == 0) return 0;
    return (math.log(value) / math.ln10 - _logMin) / span;
  }

  @override
  double invert(double t) =>
      math.pow(10, _logMin + t * (_logMax - _logMin)).toDouble();

  @override
  LogScale withDomain(double min, double max) => LogScale(min, max);
}

/// Time-as-millis. Identical math to [LinearScale], surfaced as its own type
/// so axis formatters can detect it and render dates instead of numbers.
class TimeScale extends LinearScale {
  const TimeScale(super.domainMin, super.domainMax);

  @override
  TimeScale withDomain(double min, double max) => TimeScale(min, max);
}

/// Holds an x-scale, a y-scale and the plot rectangle in pixels. The
/// projection is a hot path; we keep the math inlined and free of branches.
class CoordinateSystem {
  CoordinateSystem({
    required this.x,
    required this.y,
    required this.plot,
    this.yInverted = true,
  });

  final Scale x;
  final Scale y;
  final Rect plot;

  /// Flutter's canvas grows downward, so most charts want yInverted=true.
  final bool yInverted;

  Offset project(double dx, double dy) {
    final tx = x.normalize(dx);
    final ty = y.normalize(dy);
    final py = yInverted ? (1.0 - ty) : ty;
    return Offset(plot.left + tx * plot.width, plot.top + py * plot.height);
  }

  /// Inverse of [project] — converts a pixel to a data-space coordinate.
  /// Useful for hit-testing and tooltip alignment.
  ({double x, double y}) unproject(Offset pixel) {
    final tx = (pixel.dx - plot.left) / plot.width;
    final tyPx = (pixel.dy - plot.top) / plot.height;
    final ty = yInverted ? (1.0 - tyPx) : tyPx;
    return (x: x.invert(tx), y: y.invert(ty));
  }

  CoordinateSystem copyWith({Scale? x, Scale? y, Rect? plot}) {
    return CoordinateSystem(
      x: x ?? this.x,
      y: y ?? this.y,
      plot: plot ?? this.plot,
      yInverted: yInverted,
    );
  }
}
