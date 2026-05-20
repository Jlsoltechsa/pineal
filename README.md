# Pineal

A high-performance Flutter visualization SDK. Cartesian charts, force-directed graphs, polar diagrams, treemaps, heatmaps, Sankey flows, OHLC candlesticks, streaming oscilloscopes, virtual data grids, vector maps, virtualized Gantt timelines and SVG export — all sharing the same `Float32List`-backed core and tree-shakable from independent entry points.

```dart
PinealChart(
  yAxes: [YAxisSpec(id: 'price', min: 0, max: 200)],
  series: [
    LineSeries(id: 'a', data: DataBuffer.fromValues(samples)),
  ],
)
```

## Why

Most Flutter chart libraries either box every data point as a Dart object (so they cap out at a few thousand samples) or rebuild a `Path` from scratch every frame (so they burn the GC). Pineal is built around three principles:

- **Zero boxing.** Data lives in `Float32List`, accessed by index.
- **Zero allocations on the hot path.** Repaint never allocates a new vertex array; the painters reuse pre-sized buffers and slice them with `Float32List.sublistView`.
- **One draw call per layer.** Series collapse to `drawRawPoints` / `drawVertices` calls. Edges of a 600-link graph go through one `drawPath`; a phosphor trail goes through two `drawVertices`.

At 60–120 FPS, a 1 M point cartesian chart pans without dropping frames; a 100 KHz streaming feed renders sustainably.

## Modules

Every module is its own entry point. Import only what you need — AOT release builds tree-shake the rest.

| Entry point | What it gives you |
|-------------|-------------------|
| `package:pineal/core.dart` | Shared primitives: `DataBuffer`, `SpatialIndex`, `RTree` (STR-bulk-loaded, `Float32List`-backed), `DataAnimator`, `LTTB`, `TextCache`, `FragmentShaderLoader` |
| `package:pineal/cartesian.dart` | `PinealChart`, multi-axis support, `LineSeries`, `BarSeries`, `StackedBarSeries`, `HorizontalBarSeries`, `ScatterSeries`, `AreaSeries`, `AnimatedLineSeries`, inertia gestures, `AnchoredOverlay`, `PictureCache` |
| `package:pineal/mesh.dart` | `PinealGraph`, layouts (`ForceDirectedLayout` with Barnes-Hut, `HierarchicalLayout`, `TreeLayout`, `BalancedTreeLayout`, `ConcentricLayout`, `RadialLayout`, `GridLayout`, `RandomLayout`), `ForceSimulation`, `IsolateForceSimulation`, edge bundling, mouse-wheel zoom, container-node overlays |
| `package:pineal/polar.dart` | `PinealPolar` with `PieSeries` (donut variant) and `RadarSeries` |
| `package:pineal/heatmap.dart` | `PinealHeatmap` with `ColorRamp` LUTs, async encoding, fragment-shader hook for 24-bit value textures |
| `package:pineal/treemap.dart` | `PinealTreemap` with squarified layout (Bruls et al.) and category-aware colouring |
| `package:pineal/financial.dart` | `OhlcBuffer`, `CandlestickSeries` with volatility-preserving time-bucketed downsampling — drops into `PinealChart` |
| `package:pineal/flow.dart` | `PinealFlow` for Sankey / alluvial diagrams with Bezier ribbon rendering via `Vertices.raw` |
| `package:pineal/stream.dart` | `StreamBuffer` (circular ring), `StreamFeed` (sync / async / isolate-port ingestion), `PinealStream` with sweep + scroll modes, incremental min/max downsampling |
| `package:pineal/phosphor.dart` | `PhosphorStream` analog-trail decoration with per-vertex alpha fade, `GhostSnapshot` + `GhostOverlay` for drift analysis, `MagneticAnnotation` for data-index-anchored labels |
| `package:pineal/grid.dart` | `PinealGrid` — single-pass virtual DataGrid for million-row datasets. Edit-first: floating `TextField` overlay, IME, copy/paste (TSV), undo/redo, range selection, multi-sort, Excel-style filter popup with histogram, async sampled auto-fit, pinned columns, frozen rows, column groups, aggregate footer, CSV/JSON export, `PagedGridDataSource` for server-side pagination |
| `package:pineal/geo.dart` | Vector maps: `PolygonBuffer` over `Float32List` lon/lat, `GeoProjectionWorker` isolate (Mercator + Equirectangular projection plus ear-clipping triangulation), `GeoPainter` over `Canvas.drawVertices` (no per-frame tessellation), `GeoHitTester` R-tree over world-coord polygon AABBs (`O(log n + k)` taps), `GeoLabel` with paint-time `lon`/`lat` projection |
| `package:pineal/gantt.dart` | Virtualized chronological timelines: `TaskBuffer` (`Float64List` of `[t1, t2, lane, kind]` in epoch-µs), `SlotIndex` for `O(1 + k)` viewport-cull regardless of dataset size, `RenderGantt` `RenderBox` with bounded lane scroll, `GanttViewport` pan/zoom |
| `package:pineal/export.dart` | `SvgExporter.exportCartesian` + `ExportProfile` (screen / retina / print) with contextual decimation |
| `package:pineal/kpi.dart` | Single-number-summary cards: `KpiFunnel`, `KpiGauge`, `KpiBullet`, `KpiBoxplot`, `KpiCalendarHeatmap`. Theme tokens passed as constructor params — no implicit dependency on the host theme |
| `package:pineal/pineal.dart` | Umbrella — re-exports everything above. Convenient for prototyping; prefer narrower entry points in production |

## Getting started

```yaml
# pubspec.yaml
dependencies:
  pineal: ^1.8.0
```

### A one-line cartesian chart

```dart
import 'package:pineal/cartesian.dart';

PinealChart(
  yAxes: [YAxisSpec(id: 'y', min: 0, max: 100)],
  series: [
    LineSeries(
      id: 'a',
      data: DataBuffer.fromValues(values),
      color: Colors.blue,
    ),
  ],
)
```

### A million points

```dart
final samples = Float32List(1000000);
for (var i = 0; i < samples.length; i++) {
  samples[i] = math.sin(i / 5000) * 50 + 50;
}

PinealChart(
  yAxes: [YAxisSpec(id: 'y', min: 0, max: 100)],
  series: [
    LineSeries(
      id: 'huge',
      data: DataBuffer.fromValues(samples.toList()),
      // SummaryPolicy auto-downsamples to ~width × 3 vertices via LTTB.
    ),
  ],
)
```

### A force-directed graph

```dart
import 'package:pineal/mesh.dart';

PinealGraph(
  nodes: NodeBuffer.empty(200, radius: 9),
  edges: EdgeBuffer.fromPairs(pairs),
  layout: const ForceDirectedLayout(iterations: 240),
  liveSimulation: true,
  onNodeDoubleTap: (i) {
    // Camera zooms to the node and its neighbours.
  },
)
```

### A streaming oscilloscope

```dart
import 'package:pineal/stream.dart';

final buffer = StreamBuffer(capacity: 20000);

// 50 KHz synthetic feed, batched per frame.
late final feedTicker = createTicker((elapsed) {
  final batch = Float32List(833);
  for (var i = 0; i < batch.length; i++) {
    batch[i] = math.sin(i / 100) * 0.7 + rng.nextDouble() * 0.1;
  }
  buffer.pushAll(batch);
})..start();

PinealStream(
  buffer: buffer,
  yMin: -1.2,
  yMax: 1.2,
  mode: StreamMode.sweep,
)
```

For an analog-CRT decay trail, swap in `PhosphorStream`. For a baseline overlay, add a `GhostSnapshot.of(buffer)` and stack a `GhostOverlay` on top.

### A vector map

```dart
import 'package:pineal/geo.dart';

final viewport = GeoViewport(centerX: 0, centerY: 0, scale: 5);

PinealGeo(
  polygons: polygons,                                  // PolygonBuffer of (lon, lat)
  viewport: viewport,                                  // ChangeNotifier — pan/zoom for free
  projection: const EquirectangularProjection(),       // or MercatorProjection()
  colorOf: (i) => palette[i],                          // O(1) per visible polygon
  outlineColor: const Color(0xFF6B7480),
  labels: const [GeoLabel(text: 'Origin', lon: 0, lat: 0)],
  onPolygonTap: (i) => print('hit polygon $i'),        // R-tree, O(log n + k)
)
```

The isolate worker re-projects and ear-clips off-thread; the painter blits a cached `ui.Vertices` until the mesh revision bumps. A 9K-polygon synthetic dataset stays at 120 FPS on a drag.

### A virtualized Gantt

```dart
import 'package:pineal/gantt.dart';

final tasks = TaskBuffer.fromTasks(
  t1Micros: t1s,
  t2Micros: t2s,
  lanes: lanes,
  kinds: kinds,
);
final viewport = GanttViewport(tMin: yearStart, tMax: yearStart + 6 * 7 * 86400 * 1e6);

PinealGantt(
  tasks: tasks,
  viewport: viewport,
  styleOf: (i) => GanttTaskStyle(fill: palette[tasks.kind(i)], label: 'Task $i'),
  onTaskTap: (i) => print('hit task $i'),
)
```

`SlotIndex` buckets tasks along the time axis so the painter only touches tasks whose `[t1, t2]` intersects the viewport — `O(1 + k)` regardless of total task count. Hit-testing uses the same index.

### Export to SVG

```dart
import 'package:pineal/export.dart';

final svg = SvgExporter.exportCartesian(
  series: mySeries,
  yAxes: myAxes,
  profile: ExportProfile.print, // 300 DPI, ~3× verts of screen profile
);
File('report.svg').writeAsStringSync(svg);
```

## Performance notes

| Scenario | Frame budget at 120 FPS | Approach |
|---|---|---|
| 1 M point line chart with pan/zoom | < 8 ms | LTTB to `width × 3` vertices, picture-cache pan-blit |
| 240-node graph with live force simulation | < 8 ms | Barnes-Hut quadtree with pooled `Float32List`, edges batched via `Vertices.raw` |
| 100 KHz streaming feed, 20 K ring | < 8 ms | `pushAll` = one `setRange` memcpy; render = two `drawRawPoints` per frame, zero allocations |
| 4096 × 4096 heatmap | One draw call | CPU colour-map → `ui.Image` via `ImageDescriptor.raw`, encoded asynchronously above 65 K cells |
| 9 K vector polygons with drag pan/zoom | < 8 ms | Mercator + ear-clipping in isolate, cached `ui.Vertices` on UI thread, world-coord R-tree for taps |
| 100 K task Gantt timeline | < 8 ms | Time-axis slot index, `drawRect` per visible bar, label cache shared with cartesian axes |
| 1 M row data grid with scroll + sort + filter | < 8 ms | Single-pass `CustomPainter` over `Float32List` widths, arithmetic hit-test, async sampled auto-fit |

## Demo

The `example/` app ships thirteen tabs covering every module, an FPS readout, a runtime changelog viewer and an "Export SVG" button. Run it with:

```bash
cd example
flutter run -d linux   # or macos, windows, ios, android
```

Screenshots and a longer walkthrough live in the example's [README](example/README.md).

## Platform support

Tested on Linux, macOS and Windows desktop. Mobile (iOS / Android) works for everything except the optional `IsolateForceSimulation` path of the mesh module, which depends on `dart:isolate` and is unavailable on web. The package compiles for web; runtime guards skip the isolate path automatically.

## Acknowledgements

Thanks to Luis Mora, Jonathan López and Jonathan Blando.

## License

MIT © 2026 Sergio Velásquez Zeballos. See [LICENSE](LICENSE).

Codeveloped with Claude (Anthropic) — see commit history for the AI-pair-programming trail.
