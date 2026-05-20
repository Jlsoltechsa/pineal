import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../data/r_tree.dart';
import '../painters/text_cache.dart';
import 'geo_buffer.dart';
import 'geo_projection.dart';

/// Strategy for colouring polygons. Returning [Color.transparent] suppresses
/// the polygon entirely (the painter still passes the triangles to the GPU
/// in the same call, but they're invisible). Keep this O(1) per call —
/// invoked once per visible polygon per frame.
typedef PolygonColorOf = Color Function(int polygonIndex);

/// Paints a [TriangulatedMesh] via `Canvas.drawVertices`, colour-keyed
/// per-source-polygon.
///
/// Why drawVertices and not Path: a Path forces Skia to tessellate every
/// frame, which is the dominant cost on dense vector maps (a single country
/// dataset with `~50K` vertices spends ~12ms in path tessellation alone).
/// `drawVertices` ships pre-triangulated geometry straight to the GPU, so
/// the per-frame cost collapses to one upload + one draw call regardless
/// of polygon count.
///
/// We pre-build a `Vertices` object keyed by mesh revision so pure repaints
/// (hover, label move) don't reallocate the GPU-side buffer.
class GeoPainter extends CustomPainter {
  GeoPainter({
    required this.mesh,
    required this.colorOf,
    required this.cache,
    required this.projection,
    required this.viewport,
    this.outlinePaint,
    this.labels = const <GeoLabel>[],
    required this.textCache,
    this.debug = false,
    super.repaint,
  });

  final TriangulatedMesh? mesh;
  final PolygonColorOf colorOf;
  final bool debug;

  /// Same projection the worker uses. The painter applies it to label
  /// `(lon, lat)` at paint time so labels track pan/zoom without the host
  /// having to know about the projection state.
  final MapProjection projection;

  /// Live viewport. Pass it as the `repaint:` listenable too so pan/zoom
  /// triggers a repaint without the widget rebuilding the painter — that's
  /// what keeps label positions glued to the geometry while panning.
  final GeoViewport viewport;

  /// Optional stroke pass over polygon outlines. We draw it via
  /// `drawRawPoints(PointMode.lines)` so it stays one GPU call.
  final Paint? outlinePaint;

  final List<GeoLabel> labels;
  final TextCache textCache;

  /// Painter-instance-scoped vertex cache so the GPU-side `Vertices` object
  /// is reused across pure repaints (hover, label drift). One per widget;
  /// owning widget should `dispose()` it on unmount.
  final GeoVerticesCache cache;

  @override
  void paint(Canvas canvas, Size size) {
    final m = mesh;
    if (m == null || m.indices.isEmpty) {
      if (debug) _drawDebug(canvas, size, m);
      return;
    }

    // Build per-vertex colour buffer. We could colour per triangle and tag
    // every triangle's three vertices, but a triangulated polygon shares
    // vertices between its triangles; the simplest correct mapping is to
    // colour each vertex by the **first** polygon that references it via
    // any triangle. That's stable because polygons don't overlap.
    final colors = _resolveColors(m);
    final vertices = cache.get(m, colors);

    canvas.drawVertices(vertices, BlendMode.srcOver, Paint());

    // Outlines: walk each polygon's outer ring as line segments.
    final op = outlinePaint;
    if (op != null) {
      _drawOutlines(canvas, m, op);
    }

    // Labels are last so they sit above geometry. The TextCache means we
    // never re-layout the same string across frames; world→screen runs
    // once per label per frame (cheap — one trig + a multiply-add).
    if (labels.isNotEmpty) _drawLabels(canvas, size);

    if (debug) _drawDebug(canvas, size, m);
  }

  void _drawLabels(Canvas canvas, Size size) {
    final pcx = size.width / 2;
    final pcy = size.height / 2;
    final tmp = Float32List(2);
    for (final label in labels) {
      projection.project(label.lon, label.lat, tmp, 0);
      viewport.worldToScreen(tmp[0], tmp[1], pcx, pcy, tmp, 0);
      final sx = tmp[0], sy = tmp[1];
      // Cheap viewport reject — skip layout for labels that can't possibly
      // intersect the canvas. Margin of 64 px covers typical label widths.
      if (sx < -64 || sx > size.width + 64) continue;
      if (sy < -32 || sy > size.height + 32) continue;
      final p = textCache.paragraph(
        label.text,
        fontSize: label.fontSize,
        color: label.color,
      );
      final w = p.maxIntrinsicWidth;
      canvas.drawParagraph(
        p,
        Offset(sx - w / 2, sy - label.fontSize),
      );
    }
  }

  void _drawDebug(Canvas canvas, Size size, TriangulatedMesh? m) {
    String state;
    if (m == null) {
      state = 'mesh: null (worker has not produced output yet)';
    } else if (m.indices.isEmpty) {
      state = 'mesh: rev=${m.revision}, '
          'positions=${m.positions.length ~/ 2}, indices=0 — '
          'all polygons culled or triangulator emitted nothing';
    } else {
      // Compute screen-coord AABB of the mesh so we can tell if it sits
      // inside the canvas at all.
      var minX = double.infinity,
          minY = double.infinity,
          maxX = -double.infinity,
          maxY = -double.infinity;
      for (var i = 0; i < m.positions.length; i += 2) {
        final x = m.positions[i], y = m.positions[i + 1];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      state = 'mesh: rev=${m.revision}, '
          'positions=${m.positions.length ~/ 2}, '
          'tris=${m.triangleCount}, '
          'AABB=(${minX.toStringAsFixed(0)},${minY.toStringAsFixed(0)})..'
          '(${maxX.toStringAsFixed(0)},${maxY.toStringAsFixed(0)}), '
          'canvas=${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';
    }
    final p = textCache.paragraph(
      state,
      fontSize: 11,
      color: const Color(0xFFFFEE58),
      maxWidth: size.width - 16,
    );
    canvas.drawRect(
      Rect.fromLTWH(8, 8, size.width - 16, p.height + 8),
      Paint()..color = const Color(0xCC000000),
    );
    canvas.drawParagraph(p, const Offset(12, 12));
  }

  Int32List _resolveColors(TriangulatedMesh m) {
    final n = m.positions.length ~/ 2;
    final out = Int32List(n);
    // Walk triangles in order; first writer wins per vertex.
    for (var t = 0; t < m.triangleCount; t++) {
      final p = m.polygonAt[t];
      final c = colorOf(p).toARGB32();
      final i0 = m.indices[t * 3];
      final i1 = m.indices[t * 3 + 1];
      final i2 = m.indices[t * 3 + 2];
      if (out[i0] == 0) out[i0] = c;
      if (out[i1] == 0) out[i1] = c;
      if (out[i2] == 0) out[i2] = c;
    }
    return out;
  }

  void _drawOutlines(Canvas canvas, TriangulatedMesh m, Paint paint) {
    // We don't have ring info in the mesh after triangulation; stroke the
    // triangle edges instead. Visually identical for non-overlapping
    // polygons because shared interior edges back-paint over themselves.
    // For full ring strokes the caller can plug a ring-aware overlay.
    final segs = Float32List(m.indices.length * 4); // 2 endpoints × 2 coords
    var off = 0;
    for (var t = 0; t < m.triangleCount; t++) {
      for (var e = 0; e < 3; e++) {
        final a = m.indices[t * 3 + e];
        final b = m.indices[t * 3 + (e + 1) % 3];
        segs[off++] = m.positions[a * 2];
        segs[off++] = m.positions[a * 2 + 1];
        segs[off++] = m.positions[b * 2];
        segs[off++] = m.positions[b * 2 + 1];
      }
    }
    canvas.drawRawPoints(ui.PointMode.lines, segs, paint);
  }

  @override
  bool shouldRepaint(covariant GeoPainter old) {
    // `viewport` is wired through `super.repaint` so pan/zoom triggers a
    // repaint via the listenable, not via field-diff. We don't need to
    // compare it here.
    return old.mesh != mesh ||
        old.colorOf != colorOf ||
        old.labels != labels ||
        old.projection != projection ||
        old.outlinePaint != outlinePaint;
  }
}

/// Geographic label — anchored to a `(lon, lat)` point in the same coordinate
/// space the host app uses for [PolygonBuffer]. The painter projects it on
/// every frame using the same projection + viewport as the polygon mesh, so
/// labels track pan/zoom without the host having to recompute screen
/// coordinates. The shared [TextCache] keeps `Paragraph.layout` to one call
/// per `(text, style)` pair.
class GeoLabel {
  const GeoLabel({
    required this.text,
    required this.lon,
    required this.lat,
    this.fontSize = 11,
    this.color = const Color(0xFF222222),
  });

  final String text;
  final double lon;
  final double lat;
  final double fontSize;
  final Color color;
}

/// Hit-test surface backed by an [RTree] over polygon AABBs plus a precise
/// point-in-polygon refine on the candidates the tree returns.
///
/// **Built once per `(polygons, projection)` pair**, not per viewport
/// update — the R-tree and the projected vertex cache live in **world
/// coordinates** (post-projection, pre-viewport), so a pan or zoom only
/// changes the inverse transform applied at query time, not the index. A
/// previous version rebuilt on every mesh delivery, which was `O(n log n)`
/// per pan tick and the dominant CPU cost past ~5k polygons.
///
/// O(log n + k) where k is the number of candidate polygons whose bounding
/// box covers the cursor — typically 1–3 even on dense maps. Replaces the
/// "one GestureDetector per polygon" approach which scales linearly with
/// polygon count and falls apart past a few hundred.
class GeoHitTester {
  GeoHitTester._(this._tree, this._polygons, this._worldCache);

  /// Projects every vertex in [polygons] into world coords (using
  /// [projection]), builds an R-tree over polygon AABBs in that frame, and
  /// keeps the projected buffer for ray-casting. Reuse the same tester
  /// across viewport changes; rebuild only when [polygons] or [projection]
  /// changes.
  factory GeoHitTester.build({
    required PolygonBuffer polygons,
    required MapProjection projection,
  }) {
    final n = polygons.polygonCount;
    final src = polygons.coords;
    final world = Float32List(src.length);
    final tmp = Float32List(2);
    for (var i = 0; i < src.length; i += 2) {
      projection.project(src[i], src[i + 1], tmp, 0);
      world[i] = tmp[0];
      world[i + 1] = tmp[1];
    }

    final boxes = Float32List(n * 4);
    final ids = Int32List(n);
    for (var p = 0; p < n; p++) {
      final pr = polygons.polygonRingRange(p);
      ids[p] = p;
      if (pr.end == pr.start) continue;
      final outer = polygons.ringRange(pr.start);
      var xMin = double.infinity,
          yMin = double.infinity,
          xMax = -double.infinity,
          yMax = -double.infinity;
      for (var v = outer.start; v < outer.end; v++) {
        final x = world[v * 2], y = world[v * 2 + 1];
        if (x < xMin) xMin = x;
        if (x > xMax) xMax = x;
        if (y < yMin) yMin = y;
        if (y > yMax) yMax = y;
      }
      boxes[p * 4] = xMin;
      boxes[p * 4 + 1] = yMin;
      boxes[p * 4 + 2] = xMax;
      boxes[p * 4 + 3] = yMax;
    }
    return GeoHitTester._(
      RTree.bulkLoad(boxes: boxes, ids: ids),
      polygons,
      world,
    );
  }

  final RTree _tree;
  final PolygonBuffer _polygons;
  final Float32List _worldCache;

  /// Returns the first polygon whose outer ring contains the screen point
  /// `(sx, sy)`, projecting through [viewport] (inverse-transformed back
  /// into the world frame the tree indexes). [pcx], [pcy] are the canvas
  /// pixel center — same scalars the painter and worker use. Returns `-1`
  /// if no polygon covers the point.
  int hit(double sx, double sy, GeoViewport viewport, double pcx, double pcy) {
    final tmp = Float32List(2);
    viewport.screenToWorld(sx, sy, pcx, pcy, tmp, 0);
    final wx = tmp[0], wy = tmp[1];
    final candidates = <int>[];
    _tree.query(wx, wy, wx, wy, candidates);
    for (final p in candidates) {
      if (_pointInPolygon(p, wx, wy)) return p;
    }
    return -1;
  }

  bool _pointInPolygon(int polygon, double x, double y) {
    final pr = _polygons.polygonRingRange(polygon);
    if (pr.end == pr.start) return false;
    final outer = _polygons.ringRange(pr.start);
    var inside = _rayCast(outer.start, outer.end, x, y);
    // Holes flip parity.
    for (var r = pr.start + 1; r < pr.end; r++) {
      final rr = _polygons.ringRange(r);
      if (_rayCast(rr.start, rr.end, x, y)) inside = !inside;
    }
    return inside;
  }

  bool _rayCast(int start, int end, double x, double y) {
    var inside = false;
    var j = end - 1;
    for (var i = start; i < end; i++) {
      final xi = _worldCache[i * 2], yi = _worldCache[i * 2 + 1];
      final xj = _worldCache[j * 2], yj = _worldCache[j * 2 + 1];
      final intersect = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi);
      if (intersect) inside = !inside;
      j = i;
    }
    return inside;
  }
}

/// Owns the latest `ui.Vertices` object for a [GeoPainter]. Public so the
/// hosting widget can dispose it deterministically when it unmounts.
class GeoVerticesCache {
  ({int rev, int palette, ui.Vertices verts})? _entry;

  ui.Vertices get(TriangulatedMesh m, Int32List colors) {
    final paletteHash = Object.hashAll(colors);
    final cached = _entry;
    if (cached != null &&
        cached.rev == m.revision &&
        cached.palette == paletteHash) {
      return cached.verts;
    }
    cached?.verts.dispose();
    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      m.positions,
      indices: m.indices,
      colors: colors,
    );
    _entry = (rev: m.revision, palette: paletteHash, verts: verts);
    return verts;
  }

  void dispose() {
    _entry?.verts.dispose();
    _entry = null;
  }
}
