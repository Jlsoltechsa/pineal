import 'dart:typed_data';

/// Source representation of a vector map: many polygons packed into one
/// `Float32List` of `(lon, lat)` pairs, with offset tables that say where
/// each polygon and ring starts and ends.
///
/// Stored once in geographic coordinates and re-projected on demand into a
/// [TriangulatedMesh] (typically inside an isolate). Designed so the entire
/// dataset for, say, "world admin-1 boundaries" is a handful of `TypedData`
/// allocations, not one Dart object per shape.
///
/// Layout:
/// - `coords[i*2 .. i*2+1]`            → vertex `i` as `(lon, lat)`
/// - `ringOffsets[r]`                  → first vertex index of ring `r`
/// - `polygonRingStart[p]`             → first ring index of polygon `p`
///   (terminator entry equals `ringOffsets.length - 1`)
/// - Ring `0` of a polygon is the outer boundary; subsequent rings are holes.
class PolygonBuffer {
  PolygonBuffer({
    required this.coords,
    required this.ringOffsets,
    required this.polygonRingStart,
    Object? Function(int polygonIndex)? metadataOf,
  }) : _metadataOf = metadataOf;

  final Float32List coords;
  final Int32List ringOffsets;
  final Int32List polygonRingStart;
  final Object? Function(int polygonIndex)? _metadataOf;

  int get polygonCount => polygonRingStart.length - 1;
  int get ringCount => ringOffsets.length - 1;

  /// Vertex range covered by ring [r] (`[start, end)`, in vertex indices).
  ({int start, int end}) ringRange(int r) =>
      (start: ringOffsets[r], end: ringOffsets[r + 1]);

  /// Ring range belonging to polygon [p] (`[start, end)`).
  ({int start, int end}) polygonRingRange(int p) =>
      (start: polygonRingStart[p], end: polygonRingStart[p + 1]);

  Object? metadata(int polygonIndex) => _metadataOf?.call(polygonIndex);

  /// AABB across every vertex. Used to seed [GeoViewport] and the R-tree
  /// bulk loader.
  ({double xMin, double yMin, double xMax, double yMax}) bounds() {
    if (coords.isEmpty) return (xMin: 0, yMin: 0, xMax: 1, yMax: 1);
    var xMin = double.infinity,
        yMin = double.infinity,
        xMax = -double.infinity,
        yMax = -double.infinity;
    for (var i = 0; i < coords.length; i += 2) {
      final x = coords[i], y = coords[i + 1];
      if (x < xMin) xMin = x;
      if (x > xMax) xMax = x;
      if (y < yMin) yMin = y;
      if (y > yMax) yMax = y;
    }
    return (xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax);
  }

  /// AABB of a single polygon — used by the R-tree builder.
  ({double xMin, double yMin, double xMax, double yMax}) polygonBounds(int p) {
    final pr = polygonRingRange(p);
    if (pr.end == pr.start) return (xMin: 0, yMin: 0, xMax: 0, yMax: 0);
    final outer = ringRange(pr.start);
    var xMin = double.infinity,
        yMin = double.infinity,
        xMax = -double.infinity,
        yMax = -double.infinity;
    for (var i = outer.start; i < outer.end; i++) {
      final x = coords[i * 2], y = coords[i * 2 + 1];
      if (x < xMin) xMin = x;
      if (x > xMax) xMax = x;
      if (y < yMin) yMin = y;
      if (y > yMax) yMax = y;
    }
    return (xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax);
  }
}

/// Output of the projection + triangulation pass. Both buffers are sized to
/// be passed straight into `Canvas.drawVertices` via `Vertices.raw`.
///
/// - `positions` — interleaved `(x, y)` in **screen** coordinates.
/// - `indices`   — `Uint16List` of triangle vertex indices (3 per triangle).
/// - `polygonAt[t]` — for triangle `t` (0-indexed, so length = `indices/3`),
///   the index of the source polygon. Lets the painter colour-key tris and
///   the hit-tester resolve a tap on a triangle back to a polygon.
class TriangulatedMesh {
  TriangulatedMesh({
    required this.positions,
    required this.indices,
    required this.polygonAt,
    required this.revision,
  });

  final Float32List positions;
  final Uint16List indices;
  final Int32List polygonAt;

  /// Bumped by the producer (isolate or sync builder) on every rebuild so
  /// the painter can invalidate its cached `Vertices` object.
  final int revision;

  int get triangleCount => indices.length ~/ 3;
}

/// Ear-clipping triangulator for simple polygons (with holes).
///
/// The input is **already projected** (`xy` is screen-space-or-thereabouts)
/// because the projection's distortion would otherwise put silver triangles
/// at the poles. Holes are stitched into the outer ring by the classic
/// "bridge to nearest visible vertex" preprocessing step before clipping.
///
/// Worst case is `O(n²)`. Real-world admin polygons are typically `n < 200`,
/// so the constant matters more than the order. We deliberately avoid
/// allocation inside the inner loop — caller passes scratch buffers.
class EarClipper {
  /// Triangulates a single polygon (outer ring `coords[outerStart .. outerEnd]`
  /// plus optional holes). Appends triangle vertex indices to [outIndices]
  /// (each triangle as 3 consecutive `int` indices into the full vertex
  /// array — *not* into the local ring; pass [vertexBase] to offset them).
  static void triangulate({
    required Float32List xy,
    required int outerStart,
    required int outerEnd,
    required List<({int start, int end})> holes,
    required int vertexBase,
    required List<int> outIndices,
  }) {
    final ring = _stitchHoles(xy, outerStart, outerEnd, holes);
    final n = ring.length;
    if (n < 3) return;

    // Doubly-linked list over the working ring. `next[i]` and `prev[i]` are
    // mutated as ears are removed.
    final next = Int32List(n);
    final prev = Int32List(n);
    for (var i = 0; i < n; i++) {
      next[i] = (i + 1) % n;
      prev[i] = (i - 1 + n) % n;
    }

    // Winding sign — multiplied into every cross product so the same code
    // path triangulates both CW and CCW input. GeoJSON outer rings are CCW
    // in (lon, lat); after a Mercator + canvas-Y-flip they become CW in
    // screen space. Computing this once per polygon costs `O(n)` and frees
    // callers from caring about input convention.
    final s = _signedArea(xy, ring) >= 0 ? 1.0 : -1.0;

    var remaining = n;
    var guard = n * 2; // safety against pathological inputs
    var i = 0;
    while (remaining > 2 && guard-- > 0) {
      final a = ring[prev[i]];
      final b = ring[i];
      final c = ring[next[i]];
      if (_isEar(xy, ring, a, b, c, i, next, prev, s)) {
        outIndices
          ..add(vertexBase + a)
          ..add(vertexBase + b)
          ..add(vertexBase + c);
        next[prev[i]] = next[i];
        prev[next[i]] = prev[i];
        i = next[i];
        remaining--;
        guard = remaining * 2;
      } else {
        i = next[i];
      }
    }
  }

  /// Signed area of the working ring under shoelace. Positive → CCW in
  /// math coords (Y-up); negative → CW. The sign tells the ear test which
  /// cross-product direction means "convex".
  static double _signedArea(Float32List xy, List<int> ring) {
    var sum = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
      sum += xy[a * 2] * xy[b * 2 + 1] - xy[b * 2] * xy[a * 2 + 1];
    }
    return sum * 0.5;
  }

  /// Concatenates outer + holes into one ring, bridging each hole to the
  /// outer ring at its rightmost vertex (Eberly's recipe). The returned list
  /// holds *vertex indices into [xy]/2* in clip order.
  static List<int> _stitchHoles(Float32List xy, int outerStart, int outerEnd,
      List<({int start, int end})> holes) {
    final out = <int>[];
    for (var i = outerStart; i < outerEnd; i++) {
      out.add(i);
    }
    if (holes.isEmpty) return out;

    // Sort holes by descending rightmost x so we always bridge to a vertex
    // we haven't yet touched.
    final holeRanges = List<({int start, int end, int rightIdx, double rightX})>.from(
      holes.map((h) {
        var rightIdx = h.start;
        var rightX = xy[h.start * 2];
        for (var i = h.start + 1; i < h.end; i++) {
          final x = xy[i * 2];
          if (x > rightX) {
            rightX = x;
            rightIdx = i;
          }
        }
        return (start: h.start, end: h.end, rightIdx: rightIdx, rightX: rightX);
      }),
    )..sort((a, b) => b.rightX.compareTo(a.rightX));

    for (final h in holeRanges) {
      final bridge = _findBridge(xy, out, h.rightIdx);
      if (bridge < 0) continue;
      // Splice: outer[0..bridge] + hole[rightIdx..end) + hole[start..rightIdx]
      // + hole[rightIdx] (close hole) + outer[bridge] (close back) + rest.
      final stitched = <int>[];
      for (var i = 0; i <= bridge; i++) {
        stitched.add(out[i]);
      }
      // Walk hole starting at rightIdx, going forward and wrapping.
      final hLen = h.end - h.start;
      for (var k = 0; k < hLen; k++) {
        final idx = h.start + ((h.rightIdx - h.start + k) % hLen);
        stitched.add(idx);
      }
      stitched.add(h.rightIdx); // close the hole
      stitched.add(out[bridge]); // close back to outer
      for (var i = bridge + 1; i < out.length; i++) {
        stitched.add(out[i]);
      }
      out
        ..clear()
        ..addAll(stitched);
    }
    return out;
  }

  static int _findBridge(Float32List xy, List<int> outer, int holeVertex) {
    // Pick the outer vertex with the largest x that lies strictly to the
    // right of nothing else — fast, robust enough for admin polygons.
    var bestIdx = -1;
    var bestX = -double.infinity;
    final hy = xy[holeVertex * 2 + 1];
    for (var i = 0; i < outer.length; i++) {
      final v = outer[i];
      final vx = xy[v * 2];
      final vy = xy[v * 2 + 1];
      if ((vy - hy).abs() < (xy[holeVertex * 2 + 1] - vy).abs() + 1e9 &&
          vx > bestX) {
        bestX = vx;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  static bool _isEar(Float32List xy, List<int> ring, int a, int b, int c,
      int currentNode, Int32List next, Int32List prev, double windingSign) {
    final ax = xy[a * 2], ay = xy[a * 2 + 1];
    final bx = xy[b * 2], by = xy[b * 2 + 1];
    final cx = xy[c * 2], cy = xy[c * 2 + 1];
    final cross = ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) * windingSign;
    if (cross <= 0) return false; // reflex or colinear in this winding

    // Reject if any *other* vertex lies inside triangle (a,b,c). We must
    // skip the triangle's own corners — the point-in-triangle test
    // returns true for any point that lies on a triangle vertex (the
    // half-plane signs degenerate), so visiting a/b/c here would falsely
    // reject every legitimate ear. The loop walks `next(c)..prev(a)` —
    // the linked-list span that excludes all three corners.
    var n = next[next[currentNode]];
    final stop = prev[currentNode];
    while (n != stop) {
      final p = ring[n];
      final px = xy[p * 2], py = xy[p * 2 + 1];
      if (_pointInTriangle(px, py, ax, ay, bx, by, cx, cy)) return false;
      n = next[n];
    }
    return true;
  }

  static bool _pointInTriangle(double px, double py, double ax, double ay,
      double bx, double by, double cx, double cy) {
    final d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by);
    final d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy);
    final d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay);
    final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
    final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(hasNeg && hasPos);
  }
}
