# Changelog

## 1.9.0 — Renamed to pineal + headless PDF module

The package formerly published as `lapaloma` is now **pineal**
(`https://gitea.gioser.net/sergio/pineal-flutter`). Every entry point,
class and library identifier moved from the `lapaloma` / `Lapaloma`
prefix to `pineal` / `Pineal`. The visualization API is otherwise
unchanged.

- **Merged in the PDF viewer** formerly published as `lapaloma_pdf`, now
  the opt-in `package:pineal/pdf.dart` module. It ships
  **backend-agnostic** — the concrete `pdfx`/pdfium backend and the
  `pdfrx` dependency were dropped, so importing the module adds no
  native dependency weight. Implement `PdfBackend` for your target.
- No functional changes to the chart, grid, mesh, geo or gantt modules.

## 1.8.0 — Geo + Gantt modules

Two new entry points for renderer families that the existing chart/grid/mesh stack didn't cover. Both built on the same Float32List-buffer + RenderObject + isolate-worker pattern as the rest of Pineal — no per-feature widgets, no per-frame tessellation, hit-testing as math.

- **`package:pineal/geo.dart` — vector maps via `Canvas.drawVertices`.** Source polygons live in a `PolygonBuffer` (single `Float32List` of `(lon, lat)` plus offset tables for rings and polygons). A long-lived `GeoProjectionWorker` isolate owns a copy of the buffer, runs `MercatorProjection`/`EquirectangularProjection` + ear-clipping triangulation on demand, and ships back three TypedData buffers (`positions`, `indices`, `polygonAt`) wrapped in a `TriangulatedMesh`. The painter blits a cached `ui.Vertices` until the mesh revision bumps; pure repaints (hover, label drift) never re-upload geometry. Why this and not `Path`: a 50K-vertex country dataset spends ~12ms in path tessellation per frame; `drawVertices` collapses it to one upload + one draw call regardless of polygon count.
- **`GeoHitTester` — R-tree over polygon AABBs.** STR-bulk-loaded, `O(log n + k)` per pointer move with a precise point-in-polygon ray-cast on the candidates the tree returns. Replaces the "one `GestureDetector` per polygon" approach which costs `O(n)` per pointer event and falls apart past a few hundred shapes.
- **`RTree` in core** — promoted to `package:pineal/core.dart` since both Geo and any future spatial-query workload (Gantt drag-select, scatter brushing) can reuse the same Float32List-backed implementation. Builds and queries are allocation-free across calls — the caller owns the result list.
- **`package:pineal/gantt.dart` — virtualized chronological RenderBox.** Tasks pack into a `TaskBuffer` (interleaved `[t1, t2, lane, kind]` per task as Float64). A `SlotIndex` buckets tasks along the time axis (uniform chunks, sized heuristically to ~average-duration × 4) so a viewport query reduces to walking a contiguous slice of the slot table — `O(1 + k)` regardless of total task count, even on million-task datasets. The `RenderGantt` paints only tasks whose `[t1, t2]` intersects the visible window and whose lane intersects the lane scroll, in a single `drawRect`-per-task loop with one `drawRawPoints(Lines)` for every lane gridline. `GanttViewport` is a `ChangeNotifier`; mutating `tMin`/`tMax` via `pan`/`zoom` schedules a repaint without rebuilding the widget tree.
- **Hit-testing in Gantt** routes through the same slot index — a tap is converted to `(t, lane)`, fires one bucket query at `t`, and refines linearly inside the bucket. No per-bar `GestureDetector`.
- **Label cache shared across both modules.** `GeoPainter` and `RenderGantt` both consume a `TextCache` (the same LRU the cartesian axis painter uses) so a 200-city map or 1000-task viewport runs `Paragraph.layout` once per unique label, not once per paint per element.
- **Isolate worker coalescing.** `GeoProjectionWorker` discards stale projection requests when a newer one arrives during a pan/zoom — only the most recent viewport is honoured per worker tick, so dragging at 120Hz never queues a backlog of redundant triangulations.
- **`GeoLabel` now takes `lon`/`lat`** instead of screen `x`/`y`. The painter projects them at paint time using the same projection + viewport as the polygon mesh, so labels track pan/zoom for free — the host doesn't need to know anything about projection state. The label loop hoists a single `Float32List(2)` scratch buffer and includes a cheap viewport-reject so off-canvas labels skip `Paragraph.layout` entirely. `GeoPainter` gained `projection` + `viewport` constructor fields; `viewport` is also wired through `super.repaint` so pan/zoom triggers a repaint via the listenable rather than via a field-diff rebuild.
- **`GeoHitTester` now indexes polygon AABBs in world coordinates** (post-projection, pre-viewport) and inverse-transforms the screen-space tap into the same frame at query time. The tree is built **once per `(polygons, projection)` pair** in `initState`/`didUpdateWidget` and reused across every pan and zoom — previously the tester was rebuilt on every mesh delivery (`O(n log n)` per pan tick, dominant CPU cost past ~5K polygons). New `hit(sx, sy, viewport, pcx, pcy)` signature; `GeoViewport` gains a `screenToWorld` companion to `worldToScreen`.
- **Geo worker hoists the per-vertex `Float32List(2)`** out of the projection loop in `_runJob`. Was allocating one per vertex per request — 10K+/sec on a drag at the 24×24 chip, much more on the 96×96 chip. One alloc per request now.
- **Gantt lane scroll bounds.** `_laneScrollY` clamps to `[0, totalContentHeight − viewportHeight]` instead of `[0, ∞)`, so wheel/pinch can't push the user into empty space below the last lane. When the dataset shrinks (chip swap), a post-frame re-clamp pulls the scroll back into range so users don't land in blank space.
- **Ear-clipper winding-agnostic + correct ear test.** Two bugs fixed in `EarClipper`. (1) `triangulate` now computes the ring's signed area once and multiplies the winding sign into every cross product, so both CW and CCW input clip correctly — GeoJSON's `(lon, lat)` CCW polygons become CW after Mercator's Y-flip and were silently triangulating to nothing. (2) The "is any vertex inside this candidate ear?" sweep started at `next[currentNode]` — i.e. at the ear's own `c` corner — and `_pointInTriangle` returns true for a point coincident with a triangle vertex (the half-plane signs degenerate to zero), so every otherwise-valid ear was rejected. Sweep now starts at `next[next[currentNode]]`, walking only the genuine "other" vertices.
- **`PinealGeo.debug` flag** exposes a yellow status overlay that reports mesh state (`null` / `0 triangles` / `tris=N AABB=...`). Diagnostic for "why does my map render empty" — set it on a misbehaving map and it'll tell you whether the worker is stalled, the triangulator is emitting nothing, or the geometry is just off-canvas.
- **Library-side ticker dispose-time crash.** `_GestureHandlerState` and `_GraphGestureHandlerState` both used `late final Ticker _ticker = createTicker(_onTick);`. If the user never panned (so `_ticker` was never read) the late initializer fired for the first time inside `dispose()`, where `createTicker` is illegal — Flutter throws "looking up a deactivated widget's ancestor is unsafe". Moved both to eager initialization in `initState`. Surfaced when navigating from any chart/mesh tab into Geo, but the bug applied to every chart-using app since 0.1.0.

## 1.7.0 — Sticky section headers + paged-source hardening

Closes out the grid module's v0 → v1 arc. The next sprints should look elsewhere in Pineal.

- **Sticky section headers** — `PinealGrid.sectionOf: String? Function(int row)?` partitions display rows into named sections (think iOS `UITableView`: "Today / Yesterday / Last week"). When a row sitting at the top of the body belongs to a section, the column-header band is **replaced** by a section sticky carrying the label — pinned columns and the optional group band stay visible so per-row identity isn't lost during the takeover. Roll back as soon as scrolling lands on a row outside any section. `sectionLabel: String Function(String id)?` resolves the display name; defaults to the ID.
- **Retry with backoff** in `PagedGridDataSource` — `maxRetries` (default 3) and `retryBackoff` (default 200ms, doubling each attempt: 200/400/800ms) cover transient network blips without piling on a flaky backend. `onFetchError` only fires after the last attempt; the page-pending set is correctly released between retries so the scheduler doesn't deadlock.
- **Optimistic edits** in `PagedGridDataSource` — `setValueAt` and `writeBatch` now mutate the local page cache first, fire `writeCell` / `writeBatchCells` in the background, and roll back if the future completes with an error. Subclasses override `writeCell` (or `writeBatchCells` if their backend has a native bulk endpoint) to hit the server; the default `writeBatchCells` fans out concurrently. `onWriteError` / `onBatchWriteError` are the failure hooks (default swallows after rollback). Writes to non-cached rows drop silently since there's nothing to optimistically update against and the row isn't visible.

## 1.6.0 — Grid module refinements

Layered onto the 1.5.0 grid foundation. Each line is opt-in — defaults match the previous behavior, so existing call sites keep working.

- **Histogram in the filter popup** — numeric and date branches both draw a 30-bin histogram above the slider. Bars in the active range render in the accent color, the rest in a muted gridline tone; heights are scaled against the tallest bin so all bars fit the 32-pixel band. Bins computed from the same `uniqueValues` list the popup already loaded.
- **Group-aware column reorder** — dragging a header to a new position now restricts valid drop targets to columns inside the same `GridColumnGroup` (or, for ungrouped columns, other ungrouped columns within the same pin section). Dropping over a different group is silently rejected — the indicator simply doesn't appear there.
- **Variable-height frozen rows** — `PinealGrid.frozenRowCount` no longer forces uniform heights for the frozen band. The painter uses `rowYAt(frozen)` as the band height and the same prefix-sum buffer powers both halves, so an `autoSizeRows` grid can freeze a tall wrapped row at the top without distortion.
- **`GridColumn.cellBuilder`** — custom painter callback for the cell body. Receives a `GridCellContext { canvas, rect, value, row, column, textCache, … }`, draws whatever it wants inside `rect`. Hit-testing isn't routed through the builder; use `PinealGrid.onCellTap` for clickable cells and dispatch by column id. The grid still draws the shimmer placeholder when the value is `null`, so paged sources don't need to handle pending state inside their builders.

## 1.5.0 — Grid module (virtual DataGrid)

New entry point `package:pineal/grid.dart`. Single-pass `CustomPainter` over the same `Float32List` + `TextCache` + `RepaintBoundary` machinery the charts use: no per-cell widgets, hit-testing is arithmetic against column widths and the uniform row height, so a million-row dataset costs no more than a thousand-row one.

- **`PinealGrid`** — top-level widget; one `RepaintBoundary` for the painter plus a single overlay layer for the editor.
- **`GridDataSource`** — read/write contract decoupled from layout. `InMemoryGridDataSource` covers the eager case; lazy/paged sources only need to override `valueAt` and call `notifyListeners` when a page lands. `valueAt` returning `null` renders a shimmer placeholder.
- **`GridColumn`** — declarative spec with `width` (fixed or auto), `pin` (left / right / none), per-column `autoFit` strategy, `editable`, `formatter`, alignment, min/max width.
- **`GridController`** — `Float32List` column widths, scroll/selection/edit/sort state, `ChangeNotifier`-backed. Bulk `setWidths` so the auto-fit pipeline only fires one notification.
- **`AutoFitMeasurer`** — three layers as planned: `viewport` (sync, every layout, scans only on-screen rows), `sampled` (post-frame, stride-sampled across the whole dataset to anchor width for jitter-free scrolling), `exhaustive` (offline; intended for export).
- **`FloatingEditor`** — single shared `TextField` overlay positioned by `GridPainter.cellRect`. Enter commits and advances down, Tab commits and advances right (Shift+Tab left), Escape cancels, tap-outside commits in place. Numeric/bool columns coerce back to their original type so editing `42` doesn't poison the column with strings.
- **Pinned columns** drawn via `clipRect` + coordinate translation in the same paint pass — no separate layers, no tearing between fixed and scrolling halves.
- **Keyboard navigation** — arrow keys move the active cell with scroll-into-view, `PageUp`/`PageDown` jump by viewport height, `Ctrl+Home` / `Ctrl+End` jump to corners. `F2` or `Enter` opens the editor; any printable character opens it pre-seeded with that character (Excel "type to overwrite").
- **Column resize** — drag the 6-pixel band at the right edge of any header; the cursor switches to `resizeColumn` while hovering. Resize and pan share the same `onPanStart` classifier, so a single gesture can't conflate the two.
- **Sort by header click** — clicking a header (outside the resize zone) cycles `none → asc → desc → none`. `GridDataSource.sort(spec)` is the contract; `InMemoryGridDataSource` ships a stable sort that handles `num`, `DateTime`, `bool` and falls back to string compare. A small triangle marks the sorted column.
- **Range selection** — `GridSelection { anchor, focus }`. Shift+click extends the focus, Shift+arrows extend by one cell, Shift+PageUp/Down extend by viewport. The painter draws a translucent fill over every cell in the range plus the strong focus highlight on top.
- **Clipboard copy** — `Ctrl/Cmd+C` from grid focus (not while editing) serializes the current selection as TSV (tab-separated, newline-delimited rows) and pushes it to the system clipboard. Tabs/newlines inside cell text are stripped to spaces so the structure stays intact, same trade Excel makes.
- **Clipboard paste + delete** — `Ctrl/Cmd+V` parses TSV from the clipboard. 1×1 clipboard into a multi-cell selection fills the whole range with that value; otherwise it block-pastes anchored at the focus cell. `Delete`/`Backspace` clears every editable cell in the selection. Non-editable target columns are skipped silently; type coercion mirrors the destination's existing value type (paste `"42"` into an `int` column stays an int).
- **`GridDataSource.writeBatch`** — bulk-write contract used by paste/delete so a 100×10 paste fires one notification instead of 1000. The default falls back to one `setValueAt` per cell; `InMemoryGridDataSource` overrides it for a single consolidated emit.
- **Undo / redo** — `Ctrl/Cmd+Z` undoes, `Ctrl+Shift+Z` and `Ctrl+Y` redo (matches macOS and Windows conventions). Every mutation routes through one `_applyWrites` choke point that snapshots the pre-write values via `source.valueAt`, so editor commits, paste, delete and any future write-source share the same history without each having to opt in. Stack capped at 200 ops; either stack clears when the user makes a new edit (redo cleared) or when `clearHistory()` is called explicitly.
- **Multi-sort** — `Shift+click` on a header is additive: a fresh column appends as ascending, an already-sorted column cycles `asc → desc → removed` in place. Plain click still replaces the chain with that single column. `GridDataSource.sort(List<SortSpec> chain)` is the new contract; `InMemoryGridDataSource` runs nested stable compares so `[region asc, score desc]` keeps regions grouped with the highest score on top inside each group. The painter shows the position number beside the arrow when the chain has more than one level (`2 ↑`, `3 ↓`).
- **Async sampled auto-fit** — `AutoFitMeasurer.measureSampledAsync` yields to the event loop every 256 rows so a 1M-row sample doesn't stall paint. Text layout still happens on the UI isolate (Flutter's `Paragraph` doesn't cross isolate boundaries cleanly with font fallback in play), so this is cooperative scheduling, not true parallelism — the win is keeping the framerate above 60 while the autofit pass runs in the background. `_runSampledAutoFit` in the widget becomes async accordingly, with `mounted` checks before each commit.
- **Filtering** — `GridFilter` abstract + `TextFilter` (case-insensitive contains) + `ValueSetFilter` (categorical whitelist). `GridDataSource.applyFilters(Map<String, GridFilter>)` is the new contract; `InMemoryGridDataSource` is refactored around a stable canonical `_rows` plus a derived `_displayOrder` index list, so filter and sort compose cleanly (filtering doesn't lose the original order, sorting doesn't lose filter membership). Sort/filter changes call `clearHistory()` because the display indices in pending undo ops would otherwise point to different source rows after the reordering.
- **Excel-style filter popup** — right-click on any column header opens a 260×360 overlay with a live search box at the top and a scrollable checklist of unique values below. Search filters the visible options (does not commit a `TextFilter`); the "(Select all visible)" tristate toggles the matched subset. Apply commits a `ValueSetFilter`; Clear removes the column's filter. Pre-seeds from any existing `ValueSetFilter` so the user can re-enter the popup to edit. The funnel icon on the header lights up whenever a column has an active filter. `GridDataSource.uniqueValues(columnId, {limit})` exposes the enumeration contract — `InMemoryGridDataSource` walks the canonical row list and caps at 1000; paged sources can override with a SQL `DISTINCT` query. A "List truncated. Refine with search." footer appears when the limit is hit.
- **CSV / JSON export** — `GridExport.toCsv(...)` and `GridExport.toJson(...)`, both async with yield-every-1024-rows so a million-row export doesn't freeze the frame. They iterate via `source.valueAt`, which means the exporter sees exactly the filter + sort the user is currently viewing — no extra pipeline to keep in sync. Both accept an optional `selection: GridSelection?` argument that scopes the export to a sub-range (rows + columns spanned by the active selection). CSV follows RFC 4180 (quotes any field that contains the separator, a quote, CR or LF; doubles embedded quotes); JSON preserves `num`/`bool`/`null`/`String` natively and serializes `DateTime` as ISO 8601, falling back to `toString()` for anything else. The `Grid` example tab grows two chips (`CSV`, `JSON`) that push the exported view to the system clipboard plus a snackbar with the row count and a short preview.
- **Variable row height** — `GridController(rowHeightOf: …)` accepts an optional `int row → double` resolver. Uniform mode (the default) keeps the O(1) integer-arithmetic fast path; supplying `rowHeightOf` switches the controller to a lazy `Float64List` prefix-sum buffer with `rowYAt` / `rowAtY` doing O(log n) binary-search lookups. PageUp/Down translate "jump by viewport" through `rowYAt` so the behavior stays correct under either layout mode. The buffer is invalidated on sort, filter or explicit `invalidateRowHeights()`.
- **Width-jitter animation** — column-width refits from the sampled autofit pass now interpolate from current to target widths over 120ms with `Curves.easeOut`, so the user sees a smooth settle rather than a snap. Manual drag-resizes bypass the animation (instant feedback). Differences under 0.5px short-circuit the animation entirely to avoid kicking off a redundant ticker.
- **Column reorder** — drag any header outside the resize zone to a new position; a translucent ghost follows the pointer, a blue insertion line marks the drop target. Click-vs-drag is resolved by the gesture arena: `onTapDown` only records the header-pressed index, `onTapUp` fires the sort if the gesture didn't escalate, `onPanStart` escalates to reorder. `controller.reorderColumn(from, to)` is the underlying op — it reshuffles both `_columns` and the parallel `_widths` buffer, leaving column-ID-keyed state (sort, filter, selection) untouched. Reorder is restricted to within the same pin group (left/right/scrolling) because moving across breaks the painter's clipping assumptions.
- **Numeric range filter** — `NumericRangeFilter({min, max})`. The filter popup auto-detects numeric columns by sampling unique values: if every non-null is a `num`, the popup swaps the checklist body for a `[Min] [Max]` two-field layout with the column's observed range shown as a hint. Filtering rules: inclusive both ends; either bound `null` means open; non-numeric values fail the predicate.
- **Esc closes the filter popup** — Focus + onKeyEvent at the popup root catches Escape no matter which inner field has focus. Tab traversal between fields/buttons works via Flutter's default focus order.
- **Numeric range slider** — when the filter popup detects a numeric column, a `RangeSlider` slides in below the Min/Max fields, bound bidirectionally: dragging the slider rewrites the fields, typing into a field repositions the slider. Skips itself when the column has zero span (one unique value).
- **Date range filter** — `DateRangeFilter({min, max})` with inclusive ISO 8601 bounds. The popup's column-type detector now branches three ways: numeric / date / categorical based on the runtime type of the sampled non-null values, swapping the popup body accordingly.
- **Multi-line cells** — `GridColumn.wrap` lays the paragraph out at the cell width and top-aligns it. Pair with `PinealGrid.autoSizeRows: true` and the grid auto-measures the tallest wrapped column per row, caches the result, and invalidates the cache when column widths change (live during drag-resize). Mixing with a hand-supplied `rowHeightOf` is fine — the caller's resolver wins.
- **Column groups** — `PinealGrid.columnGroups: List<GridColumnGroup>` adds a labeled band above the column headers. Each group spans its `columnIds` in display order; non-contiguous columns (after a reorder) draw one labeled span per run. Pinned columns ignore groups and take the full header height.
- **Frozen rows** — `PinealGrid.frozenRowCount: int` pins the first N rows just below the header. Drawn after the body so partial-row bleed-through can't escape. Constrained to uniform row heights — `rowHeightOf` is ignored for the frozen rows themselves.
- **Aggregate footer** — `GridColumn.aggregate: GridAggregate.{none, count, sum, avg, min, max}` plus `PinealGrid.showAggregateFooter: true` paints a pinned footer band below the body that runs the chosen aggregate over the *displayed* rows (filter + sort applied). Results are cached on the controller and cleared on every source notification, so filter/edit changes never leave stale numbers visible.
- **Aggregate labels in footer** — `PinealGrid.aggregateFooterShowLabels: true` prefixes each footer cell with the aggregate's name (`"Sum: 1234"`, `"Avg: 47.32"`). Per-column override via `GridColumn.aggregateLabel: String?` — non-null wins (so a custom string lands every time), and the empty string explicitly suppresses the prefix even when the global flag is on.
- **`PagedGridDataSource`** — server-side base class. Subclass implements one method (`fetchPage(offset, limit, sort, filters, cursor) -> Future<PageResult>`) and gets LRU page caching, paint-time prefetch fan-out, sort/filter cache invalidation, and total-row-count bookkeeping for free. Supports both offset-based pagination (advertise `totalRowCount` directly) and cursor-based streaming (advertise `hasMore` + threading an opaque `cursor` between fetches). The grid's existing "null cell → shimmer placeholder" path handles in-flight pages without ceremony, so a million-row API-backed table needs only a `fetchPage` body.

The example app gains a `Grid` tab demoing 1k / 10k / 100k / 1M synthetic rows over 11 columns, with double-click (or `F2`) to edit and pinned `idx`/`name` (left) plus `owner` (right).

## 1.4.0 — BalancedTreeLayout (Reingold–Tilford / Buchheim)

Nuevo layout para árboles enraizados: implementación lineal-time del algoritmo de Buchheim 2002 ("Improving Walker's Algorithm to Run in Linear Time"), que es la mejora canónica del clásico Reingold–Tilford / Walker.

Comparado con el `TreeLayout` existente (que reserva ancho por subárbol y luego reparte), `BalancedTreeLayout`:

- **Subárboles iguales → layouts idénticos.** La forma del subárbol es invariante respecto a dónde esté dentro del árbol.
- **Padres centrados sobre sus hijos** sin sesgo a izquierda o derecha.
- **Sin solapamientos.** Usa contornos de subárboles (con "threads" virtuales) para empujar lo mínimo necesario.
- **Distancia configurable** entre hermanos (`siblingSeparation`) vs entre subárboles distintos (`subtreeSeparation`).
- **`O(n)`** gracias al "default ancestor" que evita recorridos cuadráticos del apportion.

Mismo input que `TreeLayout`: BFS desde `rootIndex` sobre la adyacencia indirigida, así que grafos con ciclos o multiples componentes se manejan limpio.

## 1.3.0 — PinealGraph topMostIndex (hover z-order)

- **`PinealGraph.topMostIndex: int?`** — opcional. Si se pasa, el widget de ese nodo se renderea último en el `Stack` interno, quedando por encima del resto. Útil para estados de hover / focus donde el nodo activo debe sobresalir sin alterar el layout.
- `_NodeWidgetOverlay` ahora usa `Clip.none` para que las sombras / escalas elevadas no se recorten contra el borde del gráfico.

## 1.2.0 — KPI cards module

New entry point `package:pineal/kpi.dart` for single-number-summary widgets. These sit alongside the chart modules but answer a different question: instead of showing a distribution or trend, each one reduces the data to one insight.

The `example/` app gains two tabs covering the 1.1.0 series (Scatter & Bars) and the new KPI module, each with a `Reseed` button for fresh data.

- **`KpiFunnel`** — horizontal bars decreasing along a conversion flow. Per-stage color overrides; tracks default to a neutral grey.
- **`KpiGauge`** — semicircular three-band arc with a needle. Palette length is free (default 3 bands).
- **`KpiBullet`** — actual-vs-target bar with a marker for the goal.
- **`KpiBoxplot`** — min/Q1/median/Q3/max with an optional highlighted observation marker. Empty-state message is parameterizable.
- **`KpiCalendarHeatmap`** — GitHub-style week × day grid keyed by `'YYYY-MM-DD'`. `dayLabels` is parameterizable for localization (default English; e.g. pass `['D','L','M','X','J','V','S']` for Spanish).

All five take their colors as constructor parameters with neutral defaults — host apps thread their own theme tokens at the call site. None of them reach into the host app's theme.

## 1.1.0 — Scatter, stacked bars, horizontal bars

Three new cartesian series, all exported from `package:pineal/cartesian.dart`. These are the primitives that were blocking SUMMA's analytics module from dropping `fl_chart` — see [`COVERAGE_SUMMA.md`](COVERAGE_SUMMA.md).

- **`ScatterSeries`** — unordered point cloud with optional per-point `colorOf(i)` / `radiusOf(i)` callbacks. Uniform case (no callbacks) batches every visible point into a single `drawRawPoints` call; per-point styling falls back to one `drawCircle` per point. Visible-range culling reuses the existing spatial index.
- **`StackedBarSeries`** — multiple values per category, stacked from a shared baseline. The underlying `DataBuffer` stores the per-row total so the chart's autorange works without configuration. Per-stack colors wrap modulo length; optional `cornerRadius` rounds the top corners of the highest stack only, so inner stacks stay flush.
- **`HorizontalBarSeries`** — bars laid out along the x-axis. Data convention: `x = value`, `y = category index`. Pairs naturally with `yFormatter` for category labels. Y-range culling skips off-screen rows.

## 1.0.2 — Stream pre-fill flicker fix

- **Phosphor / sweep / scroll flicker on a fresh buffer**: every stream renderer assumed the ring was already full. For the first ~100 ms after creating a new `StreamBuffer` (or toggling its capacity), slots from `head` to `capacity - 1` still held their initial zeros. `PhosphorStream` would draw them as a thick green stripe; `PinealStream` in sweep mode drew a flat baseline; the downsample envelope mapped them as a constant zero strip. All three paths now read `buffer.count >= capacity` and skip the unwritten half until the ring is full.
- **Scroll partial trace alignment**: when the ring isn't full, the raw scroll renderer and the scroll downsample cache now right-align the partial trace so it flows in from the right edge instead of stretching across the whole panel.
- **Downsample empty columns**: untouched pixel columns now emit a coincident (top == bottom) segment that drops to a degenerate zero-area line — invisible without changing the rest of the rendering pipeline.

## 1.0.1 — 1.0 honest-notes cleanup

- **PhosphorStream — real per-vertex alpha**: replaced the 16-bin chunked-alpha approximation with a thickened-line `triangleStrip` rendered through `Vertices.raw` with per-vertex color arrays. Each sample expands to two stroke-edge vertices whose alpha falls continuously with sample age. Smoother fade, no banding, and the entire trail draws in two `canvas.drawVertices` calls per frame instead of 16+. Position and color buffers are pre-allocated once and reused — zero per-frame Dart allocations.
- **GhostOverlay matrix pool**: the painter's `Float64List(16)` is now a field initialised once per painter instance instead of a per-`paint()` allocation. Constant cells (`[10] = 1`, `[15] = 1`) are pre-set in the field initialiser; `paint` only overwrites `sx`, `sy`, `tx`, `ty`.
- **MagneticAnnotationLayer — relayout listenable**: replaced the rebuild-the-Stack-per-tick approach with `CustomMultiChildLayout` whose delegate listens to a `ValueNotifier<int>` driven by the layer's own ticker. The widget tree is rebuilt only when the annotation list changes (add / remove / clear); per-frame ticking re-runs `performLayout` against the existing `RenderObject` children. `MagneticAnnotationListener` is now a deprecated no-op shim.

## 1.0.0 — Phosphor trail, ghosting, magnetic annotations, SVG export

Final SDK milestone. Five separate opt-in modules so the core stays slim.

- **`package:pineal/phosphor.dart`** — analog-CRT decorations on top of streaming.
  - `PhosphorStream`: chunked-alpha trail. The buffer is rendered in `bins` (default 16) contiguous slices walking back from the write head, each with its own alpha. Newest = 1.0 with optional `headBoost` (glow), oldest fades into the background. One `drawRawPoints(polygon)` call per bin × no per-frame allocations.
  - `GhostSnapshot.of(buffer)` + `GhostOverlay`: captures the current trace as an immutable `Float32List` copy and overlays it (translucent) on the live stream. Use for drift / deviation analysis.
  - `MagneticAnnotation` + `MagneticAnnotationLayer`: labels pinned to *absolute sample indices*. They follow the data through sweep and scroll alike; once a sample falls out of the buffer (`count - capacity > sampleIndex`) the annotation silently disappears. `MagneticAnnotationListener` re-runs layout on every buffer revision.
- **`package:pineal/export.dart`** — vectorial export.
  - `SvgExporter.exportCartesian(...)` walks a `PinealChart` definition and emits a self-contained SVG (axes, grid, polylines, paths, rects). Pure-Dart string emission, no native dependencies.
  - `ExportProfile` describes the output medium (`dpi`, `widthInches`, `heightInches`, `verticesPerPixel`). Built-ins: `screen`, `retina`, `print`. The profile drives **contextual decimation** — the same series gets ~3× more vertices in a 300-DPI print profile than in a 96-DPI screen profile, so paper output stays crisp without bloating screen exports.

Demo
- Stream tab: chips for phosphor mode, ghost capture/clear, "mark sample" (adds a yellow `MagneticAnnotation` that rides the data), clear marks.
- Cartesian tab: "Export SVG" button writes a print-profile SVG to `/tmp/pineal_<ts>.svg` and reports size in a SnackBar.

## 0.9.1 — Stream perf + mesh fixes + new layouts

Stream
- **Matrix pool**: the painter's `Float64List(16)` is now a State-owned field overwritten in place; constant cells set once at construction. Zero allocs per draw call in either mode.
- **Scroll-mode downsample**: `StreamDownsampleCache.updateScroll` walks the ring once per frame in age order, bucketing each slot into its current pixel column. Non-incremental but bounded (`O(capacity)` per frame; ~12 M ops/s at 100 K capacity × 120 FPS — well within budget). Auto-enables alongside sweep when capacity > 4 K.

Mesh
- **Mouse wheel zoom**: `GraphGestureHandler` wraps the gesture detector in a `Listener` that routes `PointerScrollEvent` to `camera.zoomAt`. Anchored at the cursor so the point under the wheel stays put.
- **Hierarchical layout cycle bug**: previous version got stuck on random graphs because cycles broke Kahn's algorithm — most nodes ended up at the fallback layer (visually all on one row). Fixed by an iterative DFS phase 0 that drops back-edges, leaving a proper DAG for the longest-path layering.
- **New layouts**:
  - `RandomLayout` — seeded `(x, y)` in a `spread × spread` square. Useful as a warm-start for force-directed.
  - `ConcentricLayout` — rings bucketed by a node-level metric (defaults to undirected degree, so hubs land at the centre). Configurable ring count and spacing.
  - `TreeLayout` — subtree-width tree drawing rooted at a chosen node. BFS spanning tree, then bottom-up width measurement, then top-down placement so siblings never overlap regardless of subtree shape.

Demo
- Mesh tab exposes the three new layout chips. Mouse wheel zoom works in the panel.

## 0.9.0 — Streaming / telemetry module

New `package:pineal/stream.dart` entry point for high-frequency telemetry. Designed to absorb 100 KHz feeds without dropping frames.

- **`StreamBuffer`**: pre-allocated ring on a `Float32List` (raw values) plus a parallel `Float32List` of `[x_norm, y]` pairs whose X coords are computed once at construction. `push` is O(1) zero-allocation; `pushAll` does the bulk update through two `setRange` memcpys (head + wrap chunk). Exposes `head`, `count`, `revision`.
- **`StreamFeed`**: three ingestion constructors — `values` (`Stream<double>`), `batches` (`Stream<Float32List>`, the recommended high-rate path), and `isolatePort` (open a `ReceivePort`; ship `SendPort` to a worker isolate that posts samples back).
- **`PinealStream`** widget: two oscilloscope modes.
  - `StreamMode.sweep` — head writes left→right, overwriting the previous trace in place. Two `drawRawPoints(PointMode.polygon)` calls per frame (split at the head so no wrap-around line). Optional vertical cursor.
  - `StreamMode.scroll` — same buffer; rendered via two translated segment views that stitch together into a continuous left-scrolling trace. Newest sample at the right edge.
- **Zero-copy rendering**: paint feeds the buffer's own coord `Float32List` straight into `canvas.drawRawPoints` via `Float32List.sublistView` (no copy). The widget applies the value→pixel mapping via a single `canvas.transform` so the buffer never has to be rewritten in pixel space.
- **Incremental min/max downsampling** (`StreamDownsampleCache`): for very dense buffers in sweep mode, keeps a `pixelColumns × (min, max)` table and only recomputes columns whose slots were touched since the previous frame. Renders the envelope as one `drawRawPoints(PointMode.lines)` call. Per-frame work scales with samples written that frame, not buffer capacity. Auto-enables when capacity > 4 K.

Demo
- New "Stream" tab. Synthetic signal (5 Hz fundamental + 47 Hz harmonic + noise) driven by a `Ticker`-based feed at 10 K / 50 K / 100 K samples per second. Ring capacities 2 K – 100 K. Toggle between sweep and scroll.

## 0.8.1 — Treemap fix + remaining optimizations

- **Treemap bug fix**: `squarify` was emitting degenerate rectangles — typical scene was one giant tile under the root label ("Portfolio") with a single sibling color. Rewrote against the canonical d3-hierarchy formulation: greedy row growth, break when adding the next value would worsen the worst aspect ratio.
- **Treemap visual polish**: per-leaf coloring derived from the depth-1 category ancestor with a per-leaf brightness wobble so siblings remain distinguishable. Internal nodes get a translucent background tint + header label with their total value. `TreemapTile.categoryId` is now part of the layout output so painters can preserve the hierarchy visually.
- **Sankey O(L log L) crossing count**: replaced the pairwise check inside the barycenter loop with merge-sort inversion counting. Same numerical result, but the layout now scales to hundreds of links without choking.
- **Heatmap 24-bit shader path**: the value-texture encoding used by `customShader` now packs the normalised value across R / G / B (was 8 bits in R alone). GLSL decode is one line: `s.r + s.g/256.0 + s.b/65536.0`. Roughly 16 million levels instead of 256.

## 0.8.0 — Module optimizations

Honest follow-ups to the limitations called out in 0.7.0.

- **Sankey iterative ordering**: `FlowLayout` now runs barycenter passes (alternating down/up) until the inter-column crossing count stops decreasing. `maxOrderingIterations: 16` cap. Same shape as the Sugiyama loop in `HierarchicalLayout`. Visibly cleaner on 20+ node diagrams.
- **OHLC time-bucketed downsampling**: `OhlcDownsample.aggregate` switches from index-uniform to time-uniform buckets. Gaps (weekends, holidays, tick irregularities) no longer collapse uneven time spans into one candle. Index-based path kept as fallback when timestamps are degenerate.
- **CandlestickSeries batched render**: bodies emit as triangle vertices via `Vertices.raw` and wicks via `drawRawPoints(PointMode.lines)`. Two groups (bull / bear) × 2 passes = 4 GPU calls total, regardless of candle count. ~10× reduction in calls at 5K candles.
- **Heatmap async encoding**: color mapping runs via `compute()` on a worker isolate above `asyncThresholdCells` (default 65 536). UI thread stays free during data swaps.
- **Heatmap shader hook**: `PinealHeatmap.customShader` accepts a `FragmentShader`. When set, the matrix is encoded as a value-only texture (R = quantised value, A = 255) and bound to sampler 0; the GLSL program owns the color ramp. Animate the ramp without re-encoding the bitmap.

## 0.7.0 — Specialized projection modules

Five new entry points, each independent so `cartesian.dart`-only apps don't pay for them at AOT time.

- **`package:pineal/polar.dart`** — `PinealPolar` widget with `PieSeries` (donut variant via `innerRadius`) and `RadarSeries` (multi-layer overlays with auto-drawn grid + axis labels). Slice/sector hit-testing in O(1) via angle/radius math, no per-element gesture detectors.
- **`package:pineal/heatmap.dart`** — `HeatmapData` (Float32List matrix) → CPU color-mapped → `ui.Image` via `ImageDescriptor.raw`. One quad, one draw call, regardless of cell count. `ColorRamp.viridis()` / `.heat()` / `.greyscale()` builtins; custom stops supported.
- **`package:pineal/treemap.dart`** — Squarified treemap (Bruls et al.) with `TreemapNode` recursive structure. Flat rect list rendered by a single painter; tap detection walks the list in reverse depth (no widget per cell).
- **`package:pineal/financial.dart`** — `OhlcBuffer` (interleaved `[t,o,h,l,c,v]`) + `CandlestickSeries` that plugs into the cartesian engine. `OhlcDownsample` aggregates by index range, preserving wick extremes (volatility) instead of just value silhouettes.
- **`package:pineal/flow.dart`** — `PinealFlow` Sankey/alluvial diagrams. Topological column layout + per-column flow stacking. Bezier ribbons emitted as triangle strips via `Vertices.raw` — one `drawVertices` per link, configurable subdivision count.

## 0.6.0 — Heavy optimizations

- **IsolateForceSimulation**: physics runs in a long-lived isolate, streams `Float32List` position snapshots to the UI thread via `SendPort`. Drag/pin/move commands flow the other direction. Frees the UI thread to render even when the graph is recomputing.
- **Sugiyama iterative**: barycenter passes loop until the edge-crossing count stops improving (`maxIterations` cap). Halves crossings on 2–3 rounds in typical DAGs.
- **FDEB iterative bundling**: Holten-style annealed refinement. Each iteration halves the step size while pulling control points toward directionally-compatible neighbours. Visible bundles even on noisy graphs.
- **Barnes-Hut buffer pool**: quadtree backing `Float32List` is reused frame-to-frame inside `ForceStepper`. No per-step allocation, no GC churn during live simulation.

## 0.5.0 — Mesh module

- New `package:pineal/mesh.dart` entry point.
- `NodeBuffer` (interleaved `[x, y, r]`) and `EdgeBuffer` (`[src, tgt]`).
- `GraphCamera` (scale + translate only, no Matrix4 overhead) + `GraphCameraController` for cinematic transitions.
- `SpatialHash` for O(1) hit-testing.
- Layouts: `GridLayout`, `RadialLayout` (single-ring or BFS rings), `HierarchicalLayout` (Sugiyama-lite), `ForceDirectedLayout` (Barnes-Hut quadtree).
- `ForceSimulation`: live ticking with alpha cooling, pin/unpin/drag.
- `EdgeRenderer`: straight / bezier / bundled, one draw call each.
- `NodeRenderer`: per-node loop ≤ 256 nodes, batched `Vertices.raw` above.
- `PinealGraph` widget: declarative, `onNodeTap`/`onNodeDoubleTap`, `nodeBuilders` for container nodes mounted as Flutter widgets.

## 0.4.0 — Modular entry points

- Split into `core.dart` / `cartesian.dart` / `mesh.dart` / `pineal.dart` (umbrella).
- AOT release builds tree-shake unused modules. Demo imports `cartesian.dart` + `mesh.dart` separately.

## 0.3.0 — Bug fixes + FPS

- **Clip leak**: `PictureCache.tryReplay` now clips to the plot rect on the outer canvas before translating. Previously the picture's embedded clip moved with the translation and spilled out of the plot.
- FPS counter in the demo (rolling 60-frame average via `Ticker`).

## 0.2.0 — Data intelligence + aesthetic pipeline

- `SummaryPolicy`: density `N/px > 2.0` activates LTTB with output capped at `width × 3` vertices.
- `DataAnimator` + `AnimatedLineSeries`: tween between summarized snapshots without re-running the reducer per frame.
- `AreaSeries`: `useVertices: true` for triangle-strip rendering, `GlowEffect`, `Shader` hook.
- `FragmentShaderLoader`: cached `FragmentProgram.fromAsset`.
- `summarizeInIsolate`: LTTB on a worker isolate via `compute()`.
- Axis decimation: labels dropped when `minLabelSpacing` (default 48 px) is violated.
- `DataBuffer.revision` for cache invalidation on in-place mutations.

## 0.1.0 — Cartesian core

- `PinealChart` widget with multi-axis support.
- Series: `LineSeries`, `BarSeries`, `AreaSeries`.
- `Float32List`-backed `DataBuffer` (no boxing, no GC).
- `LTTB` downsampling.
- `SpatialIndex` (binary search) for O(log n) tooltips.
- `InteractionLayer` in its own `RepaintBoundary` (crosshair + tooltip).
- `GestureHandler` with friction-based pan inertia and pinch zoom.
- `TextCache` (LRU) for axis labels.
- `PictureCache` for pan-only blits.
- `AnchoredOverlay`: widgets pinned to data coordinates, only visible ones mounted.
