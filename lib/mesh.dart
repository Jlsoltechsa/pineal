/// Pineal mesh — interactive node/edge graphs with force-directed layout.
///
/// Importing this entry point pulls in [core.dart] automatically and adds
/// everything needed to render graphs: layouts, force simulation, camera,
/// edge/node renderers, hit-testing and the [PinealGraph] widget. Apps
/// that only import `cartesian.dart` won't pay for any of it in release
/// builds.
library pineal.mesh;

export 'core.dart';

export 'src/mesh/node_buffer.dart';
export 'src/mesh/edge_buffer.dart';
export 'src/mesh/spatial_hash.dart';

export 'src/mesh/graph_camera.dart';
export 'src/mesh/graph_simulation.dart';
export 'src/mesh/force_simulation.dart';
export 'src/mesh/isolate_force_simulation.dart';
export 'src/mesh/edge_renderer.dart';
export 'src/mesh/node_renderer.dart';
export 'src/mesh/graph_painter.dart';
export 'src/mesh/graph_gestures.dart';

export 'src/mesh/layouts/graph_layout.dart';
export 'src/mesh/layouts/grid_layout.dart';
export 'src/mesh/layouts/radial_layout.dart';
export 'src/mesh/layouts/hierarchical_layout.dart';
export 'src/mesh/layouts/force_directed_layout.dart';
export 'src/mesh/layouts/random_layout.dart';
export 'src/mesh/layouts/concentric_layout.dart';
export 'src/mesh/layouts/tree_layout.dart';
export 'src/mesh/layouts/balanced_tree_layout.dart';

export 'src/widgets/pineal_graph.dart';
