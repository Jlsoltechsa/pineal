import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'geo_buffer.dart';
import 'geo_projection.dart';

/// Long-lived isolate worker that owns the source [PolygonBuffer] and
/// re-projects + triangulates it on demand.
///
/// The UI thread sends one [GeoProjectionRequest] per viewport change; the
/// worker replies with a [TriangulatedMesh] payload (just three TypedData
/// buffers — projection runs in pure double math, triangulation is
/// allocation-light).
///
/// Why isolate-side triangulation: the cliping math is `O(n²)` per polygon
/// and a real-world country dataset has thousands of polygons. Doing it on
/// the UI thread costs a frame; doing it in a worker keeps gestures fluid
/// and lets us coalesce requests (the worker discards stale requests if a
/// newer one is queued).
class GeoProjectionWorker {
  GeoProjectionWorker._(this._isolate, this._toIsolate, this._fromIsolate);

  final Isolate _isolate;
  final SendPort _toIsolate;
  final ReceivePort _fromIsolate;

  StreamController<TriangulatedMesh>? _meshes;
  int _revision = 0;

  /// Spawns a worker pre-loaded with [polygons] and [projection]. The buffers
  /// inside [polygons] cross the isolate boundary as TransferableTypedData,
  /// so the UI thread doesn't pay a copy.
  static Future<GeoProjectionWorker> spawn({
    required PolygonBuffer polygons,
    MapProjection projection = const MercatorProjection(),
  }) async {
    final fromIsolate = ReceivePort();
    // Send a defensive copy of each buffer so the UI thread can keep using
    // its own (the R-tree builder reads `polygons.coords` after spawn).
    final init = _IsolateInit(
      sendPort: fromIsolate.sendPort,
      coords: Float32List.fromList(polygons.coords),
      ringOffsets: Int32List.fromList(polygons.ringOffsets),
      polygonRingStart: Int32List.fromList(polygons.polygonRingStart),
      projectionKind: projection is EquirectangularProjection
          ? _ProjectionKind.equirectangular
          : _ProjectionKind.mercator,
    );
    final isolate = await Isolate.spawn(
      _isolateEntry,
      init,
      debugName: 'pineal.geo',
    );

    // Route every message through one subscription. The first one is the
    // worker's SendPort handshake; everything after is mesh payloads. We
    // need a single listen() call because ReceivePort is single-subscription.
    final ready = Completer<SendPort>();
    late final GeoProjectionWorker worker;
    fromIsolate.listen((Object? msg) {
      if (!ready.isCompleted && msg is SendPort) {
        ready.complete(msg);
        return;
      }
      worker._onMessage(msg);
    });
    final toIsolate = await ready.future;
    worker = GeoProjectionWorker._(isolate, toIsolate, fromIsolate);
    return worker;
  }

  /// Stream of fresh meshes. The widget keeps the latest mesh for paint;
  /// older ones are discarded by `revision` comparison in the painter.
  Stream<TriangulatedMesh> get meshes =>
      (_meshes ??= StreamController<TriangulatedMesh>.broadcast()).stream;

  /// Asks the worker to project + triangulate against the supplied screen
  /// transform. The math is the same `worldToScreen` the projection's own
  /// viewport would do, but we ship the two scalars + offset across so the
  /// worker doesn't need a [GeoViewport] instance.
  void requestProjection({
    required double centerWorldX,
    required double centerWorldY,
    required double scale,
    required double pxCenterX,
    required double pxCenterY,
    required double pxWidth,
    required double pxHeight,
  }) {
    _revision++;
    _toIsolate.send(<String, Object>{
      'op': 'project',
      'rev': _revision,
      'cx': centerWorldX,
      'cy': centerWorldY,
      's': scale,
      'pcx': pxCenterX,
      'pcy': pxCenterY,
      'w': pxWidth,
      'h': pxHeight,
    });
  }

  void _onMessage(Object? msg) {
    if (msg is! Map) return;
    final positions = msg['positions'] as Float32List?;
    final indices = msg['indices'] as Uint16List?;
    final polygonAt = msg['polygonAt'] as Int32List?;
    final rev = msg['rev'] as int?;
    if (positions == null || indices == null || polygonAt == null || rev == null) {
      return;
    }
    _meshes?.add(TriangulatedMesh(
      positions: positions,
      indices: indices,
      polygonAt: polygonAt,
      revision: rev,
    ));
  }

  void dispose() {
    _toIsolate.send(<String, Object>{'op': 'dispose'});
    _fromIsolate.close();
    _meshes?.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

enum _ProjectionKind { equirectangular, mercator }

class _IsolateInit {
  _IsolateInit({
    required this.sendPort,
    required this.coords,
    required this.ringOffsets,
    required this.polygonRingStart,
    required this.projectionKind,
  });

  final SendPort sendPort;
  final Float32List coords;
  final Int32List ringOffsets;
  final Int32List polygonRingStart;
  final _ProjectionKind projectionKind;
}

void _isolateEntry(_IsolateInit init) {
  final polygons = PolygonBuffer(
    coords: init.coords,
    ringOffsets: init.ringOffsets,
    polygonRingStart: init.polygonRingStart,
  );
  final projection = init.projectionKind == _ProjectionKind.equirectangular
      ? const EquirectangularProjection()
      : const MercatorProjection();

  // Reuse one screen-space buffer across requests — same length as the input
  // (one (x,y) per source vertex).
  final screen = Float32List(polygons.coords.length);

  final inbox = ReceivePort();
  init.sendPort.send(inbox.sendPort);

  // Pending request coalescing: the worker only honours the most recent
  // request that arrived while it was busy. Older revisions are dropped.
  Map<String, Object>? pending;
  var working = false;

  inbox.listen((Object? raw) {
    if (raw is! Map) return;
    final msg = Map<String, Object>.from(raw);
    final op = msg['op'] as String?;
    if (op == 'dispose') {
      inbox.close();
      Isolate.current.kill();
      return;
    }
    if (op != 'project') return;
    pending = msg;
    if (working) return;
    working = true;
    scheduleMicrotask(() {
      while (pending != null) {
        final job = pending!;
        pending = null;
        final mesh = _runJob(polygons, projection, screen, job);
        init.sendPort.send(<String, Object>{
          'positions': mesh.positions,
          'indices': mesh.indices,
          'polygonAt': mesh.polygonAt,
          'rev': job['rev'] as int,
        });
      }
      working = false;
    });
  });
}

TriangulatedMesh _runJob(
  PolygonBuffer polygons,
  MapProjection projection,
  Float32List screen,
  Map<String, Object> job,
) {
  final cx = job['cx'] as double;
  final cy = job['cy'] as double;
  final s = job['s'] as double;
  final pcx = job['pcx'] as double;
  final pcy = job['pcy'] as double;
  final pxW = job['w'] as double;
  final pxH = job['h'] as double;

  // 1. Project every vertex into screen space in one tight pass. `tmp` is
  //    hoisted out of the loop and reused — without this we'd allocate one
  //    Float32List per vertex (10K+/sec on a drag at 24×24, much more on
  //    the 96×96 chip).
  final src = polygons.coords;
  final tmp = Float32List(2);
  for (var i = 0; i < src.length; i += 2) {
    final lon = src[i];
    final lat = src[i + 1];
    projection.project(lon, lat, tmp, 0);
    screen[i] = pcx + (tmp[0] - cx) * s;
    screen[i + 1] = pcy + (tmp[1] - cy) * s;
  }

  // 2. Cull polygons whose AABB lies entirely outside the viewport rect,
  //    triangulate the survivors. The painter still benefits from culling
  //    because the index buffer ends up smaller.
  final triIndices = <int>[];
  final triPolygon = <int>[];
  final viewLeft = pcx - pxW / 2;
  final viewTop = pcy - pxH / 2;
  final viewRight = pcx + pxW / 2;
  final viewBottom = pcy + pxH / 2;

  for (var p = 0; p < polygons.polygonCount; p++) {
    final pr = polygons.polygonRingRange(p);
    if (pr.end == pr.start) continue;
    final outer = polygons.ringRange(pr.start);
    if (outer.end - outer.start < 3) continue;

    // AABB of the projected outer ring.
    var bxMin = double.infinity,
        byMin = double.infinity,
        bxMax = -double.infinity,
        byMax = -double.infinity;
    for (var v = outer.start; v < outer.end; v++) {
      final x = screen[v * 2], y = screen[v * 2 + 1];
      if (x < bxMin) bxMin = x;
      if (x > bxMax) bxMax = x;
      if (y < byMin) byMin = y;
      if (y > byMax) byMax = y;
    }
    if (bxMax < viewLeft || bxMin > viewRight) continue;
    if (byMax < viewTop || byMin > viewBottom) continue;

    final holes = <({int start, int end})>[];
    for (var r = pr.start + 1; r < pr.end; r++) {
      holes.add(polygons.ringRange(r));
    }

    final before = triIndices.length;
    EarClipper.triangulate(
      xy: screen,
      outerStart: outer.start,
      outerEnd: outer.end,
      holes: holes,
      vertexBase: 0,
      outIndices: triIndices,
    );
    final tris = (triIndices.length - before) ~/ 3;
    for (var t = 0; t < tris; t++) {
      triPolygon.add(p);
    }
  }

  // The screen buffer is shared across paints; copy so the UI thread can
  // hold onto it past the next request.
  final positionsCopy = Float32List.fromList(screen);
  final indices = Uint16List.fromList(triIndices);
  final polygonAt = Int32List.fromList(triPolygon);
  return TriangulatedMesh(
    positions: positionsCopy,
    indices: indices,
    polygonAt: polygonAt,
    revision: 0,
  );
}
