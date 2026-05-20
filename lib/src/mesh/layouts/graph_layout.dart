import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';

/// Strategy for assigning `(x, y)` to each node in a graph.
///
/// One-shot: callers invoke [apply] once and get a finished layout. Live
/// force-directed simulations use a separate controller class instead of
/// this interface.
abstract class GraphLayout {
  const GraphLayout();
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds});
}
