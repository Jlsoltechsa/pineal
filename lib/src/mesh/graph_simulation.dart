import 'package:flutter/foundation.dart';

/// Contract every force simulation backend satisfies.
///
/// Lets [PinealGraph] (and the gesture handler) accept either an
/// in-thread [ForceSimulation] or an [IsolateForceSimulation] without
/// caring where the physics runs.
abstract class GraphSimulation extends ChangeNotifier {
  /// Pin a node so the simulation stops moving it (until [unpin]).
  void pin(int index);

  /// Release a previously pinned node.
  void unpin(int index);

  /// Replace a pinned node's position. Triggers an immediate repaint and,
  /// when backed by an isolate, forwards the new position to the worker.
  void movePinned(int index, double x, double y);

  /// Bump alpha back up so the layout wakes from rest. Default is a strong
  /// re-heat; pass a smaller value for a gentle nudge.
  void reheat({double alpha = 0.6});

  /// Resume integration if currently paused.
  void start();

  /// Pause integration without disposing the simulation.
  void stop();
}
