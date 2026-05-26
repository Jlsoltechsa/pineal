/// Pineal geo — vector map renderer for high-density polygon datasets.
///
/// Built on `Canvas.drawVertices` over `Float32List` triangulations rather
/// than `Path`, so a country-admin-1 dataset (≈50K vertices) draws in a
/// single GPU call without per-frame tessellation. Projection and ear-
/// clipping run in a long-lived isolate; the painter only blits the cached
/// `ui.Vertices` until the worker pushes a new mesh.
///
/// Hit-testing uses an STR-bulk-loaded R-tree over polygon AABBs plus a
/// point-in-polygon refine on candidates — `O(log n + k)` per pointer move,
/// regardless of polygon count. No per-polygon `GestureDetector`.
library;

export 'core.dart';

export 'src/geo/geo_buffer.dart';
export 'src/geo/geo_projection.dart';
export 'src/geo/geo_isolate.dart';
export 'src/geo/geo_painter.dart';

export 'src/widgets/pineal_geo.dart';
