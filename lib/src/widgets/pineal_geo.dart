import 'dart:async';

import 'package:flutter/widgets.dart';

import '../geo/geo_buffer.dart';
import '../geo/geo_isolate.dart';
import '../geo/geo_painter.dart';
import '../geo/geo_projection.dart';
import '../painters/text_cache.dart';

/// Vector map widget. Owns the [GeoProjectionWorker], the latest mesh, and
/// the painter cache; the host app supplies the [PolygonBuffer] (typically
/// loaded from a topojson/shapefile pipeline once at startup) and a colour
/// strategy.
///
/// Rebuilds and pointer interactions never tessellate — the worker handles
/// projection/triangulation off-thread, and the painter blits the cached
/// `ui.Vertices` until the mesh revision bumps.
class PinealGeo extends StatefulWidget {
  const PinealGeo({
    super.key,
    required this.polygons,
    required this.viewport,
    required this.colorOf,
    this.projection = const MercatorProjection(),
    this.labels = const <GeoLabel>[],
    this.outlineColor,
    this.onPolygonTap,
    this.debug = false,
  });

  final PolygonBuffer polygons;
  final GeoViewport viewport;
  final PolygonColorOf colorOf;
  final MapProjection projection;
  final List<GeoLabel> labels;
  final Color? outlineColor;
  final void Function(int polygonIndex)? onPolygonTap;

  /// Draws a yellow status line over the canvas describing mesh state
  /// (`mesh null`, `0 triangles`, or `tris=N AABB=...`). Use to diagnose
  /// when a map shows up empty: the line tells you whether the worker is
  /// stalled, the triangulator is emitting nothing, or the geometry is
  /// off-canvas.
  final bool debug;

  @override
  State<PinealGeo> createState() => _PinealGeoState();
}

class _PinealGeoState extends State<PinealGeo> {
  GeoProjectionWorker? _worker;
  TriangulatedMesh? _mesh;
  StreamSubscription<TriangulatedMesh>? _sub;
  GeoHitTester? _hitTester;
  final _cache = GeoVerticesCache();
  final _textCache = TextCache(maxEntries: 512);
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    widget.viewport.addListener(_requestProjection);
    _hitTester = GeoHitTester.build(
      polygons: widget.polygons,
      projection: widget.projection,
    );
    _spawnWorker();
  }

  @override
  void didUpdateWidget(covariant PinealGeo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport) {
      oldWidget.viewport.removeListener(_requestProjection);
      widget.viewport.addListener(_requestProjection);
      _requestProjection();
    }
    if (oldWidget.polygons != widget.polygons ||
        oldWidget.projection != widget.projection) {
      _hitTester = GeoHitTester.build(
        polygons: widget.polygons,
        projection: widget.projection,
      );
    }
  }

  Future<void> _spawnWorker() async {
    final w = await GeoProjectionWorker.spawn(
      polygons: widget.polygons,
      projection: widget.projection,
    );
    if (!mounted) {
      w.dispose();
      return;
    }
    _worker = w;
    _sub = w.meshes.listen((m) {
      if (!mounted) return;
      // Hit-tester lives in world coords now — no rebuild on mesh delivery.
      setState(() => _mesh = m);
    });
    _requestProjection();
  }

  void _requestProjection() {
    final w = _worker;
    if (w == null) return;
    if (_lastSize == Size.zero) return;
    w.requestProjection(
      centerWorldX: widget.viewport.centerX,
      centerWorldY: widget.viewport.centerY,
      scale: widget.viewport.scale,
      pxCenterX: _lastSize.width / 2,
      pxCenterY: _lastSize.height / 2,
      pxWidth: _lastSize.width,
      pxHeight: _lastSize.height,
    );
  }

  @override
  void dispose() {
    widget.viewport.removeListener(_requestProjection);
    _sub?.cancel();
    _worker?.dispose();
    _cache.dispose();
    _textCache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _lastSize) {
          _lastSize = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _requestProjection();
          });
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final ht = _hitTester;
            if (ht == null || _lastSize == Size.zero) return;
            final p = ht.hit(
              d.localPosition.dx,
              d.localPosition.dy,
              widget.viewport,
              _lastSize.width / 2,
              _lastSize.height / 2,
            );
            if (p >= 0) widget.onPolygonTap?.call(p);
          },
          child: CustomPaint(
            size: Size.infinite,
            painter: GeoPainter(
              mesh: _mesh,
              debug: widget.debug,
              colorOf: widget.colorOf,
              cache: _cache,
              textCache: _textCache,
              labels: widget.labels,
              projection: widget.projection,
              viewport: widget.viewport,
              repaint: widget.viewport,
              outlinePaint: widget.outlineColor == null
                  ? null
                  : (Paint()
                    ..color = widget.outlineColor!
                    ..strokeWidth = 0.5
                    ..style = PaintingStyle.stroke),
            ),
          ),
        );
      },
    );
  }
}

