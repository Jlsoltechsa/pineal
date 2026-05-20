import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Maps `(lon, lat)` in degrees to a unit-less world frame. Implementations
/// must stay free of `dart:ui` so the projection can run inside an isolate
/// alongside the triangulator.
abstract class MapProjection {
  const MapProjection();

  /// Writes the projected `(x, y)` into [out] at `[outOffset, outOffset+1]`.
  /// Hot path — keep branchless.
  void project(double lonDeg, double latDeg, Float32List out, int outOffset);

  /// World-frame bounds the projection can produce. Used to seed viewports.
  ({double xMin, double yMin, double xMax, double yMax}) get worldBounds;
}

/// Plate carrée. `x = lon`, `y = lat`. Cheap, distortion-heavy at the poles —
/// the right default for thumbnails and dashboards that don't need conformal
/// shapes.
class EquirectangularProjection extends MapProjection {
  const EquirectangularProjection();

  @override
  void project(double lonDeg, double latDeg, Float32List out, int outOffset) {
    out[outOffset] = lonDeg;
    out[outOffset + 1] = -latDeg; // canvas Y grows downward
  }

  @override
  ({double xMin, double yMin, double xMax, double yMax}) get worldBounds =>
      (xMin: -180, yMin: -90, xMax: 180, yMax: 90);
}

/// Web Mercator (spherical). The variant every tile server uses. Singular at
/// the poles — we clamp |lat| ≤ 85.05113° to keep the world a square.
class MercatorProjection extends MapProjection {
  const MercatorProjection();

  static const double _maxLat = 85.05112877980659;

  @override
  void project(double lonDeg, double latDeg, Float32List out, int outOffset) {
    final lat = latDeg.clamp(-_maxLat, _maxLat).toDouble();
    final latRad = lat * math.pi / 180.0;
    final mercY = math.log(math.tan(math.pi / 4 + latRad / 2));
    out[outOffset] = lonDeg * math.pi / 180.0;
    out[outOffset + 1] = -mercY; // canvas Y grows downward
  }

  @override
  ({double xMin, double yMin, double xMax, double yMax}) get worldBounds {
    const k = math.pi;
    return (xMin: -k, yMin: -k, xMax: k, yMax: k);
  }
}

/// Viewport for a [MapProjection]. Translates world-frame `(x, y)` to pixels.
/// Listenable so the widget can re-fire isolate requests on every change
/// without needing a separate gesture-side bridge.
class GeoViewport extends ChangeNotifier {
  GeoViewport({
    required double centerX,
    required double centerY,
    required double scale,
  })  : _centerX = centerX,
        _centerY = centerY,
        _scale = scale;

  double _centerX;
  double _centerY;
  double _scale;

  double get centerX => _centerX;
  double get centerY => _centerY;

  /// Pixels per world unit. For Mercator (radians) at zoom 0 this is roughly
  /// `256 / (2π) ≈ 40.74`; multiply by 2^zoom for slippy-map zoom levels.
  double get scale => _scale;

  void setCenter(double x, double y) {
    if (x == _centerX && y == _centerY) return;
    _centerX = x;
    _centerY = y;
    notifyListeners();
  }

  void setScale(double s) {
    if (s == _scale) return;
    _scale = s;
    notifyListeners();
  }

  void panPixels(double dxPx, double dyPx) {
    if (dxPx == 0 && dyPx == 0) return;
    _centerX -= dxPx / _scale;
    _centerY -= dyPx / _scale;
    notifyListeners();
  }

  void worldToScreen(double wx, double wy, double pxCenterX, double pxCenterY,
      Float32List out, int outOffset) {
    out[outOffset] = pxCenterX + (wx - _centerX) * _scale;
    out[outOffset + 1] = pxCenterY + (wy - _centerY) * _scale;
  }

  /// Inverse of [worldToScreen]. Used by hit-testing to map a tap back into
  /// the world-coord frame the R-tree indexes.
  void screenToWorld(double sx, double sy, double pxCenterX, double pxCenterY,
      Float32List out, int outOffset) {
    assert(_scale != 0, 'GeoViewport.scale must be non-zero');
    out[outOffset] = (sx - pxCenterX) / _scale + _centerX;
    out[outOffset + 1] = (sy - pxCenterY) / _scale + _centerY;
  }
}
