import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../stream/stream_buffer.dart';

/// Annotation pinned to an absolute sample index in a [StreamBuffer].
///
/// Unlike screen-space markers, magnetic annotations follow the data: in
/// sweep mode they sit where the corresponding slot lives; in scroll mode
/// they ride along as the trace shifts. Once the underlying sample falls
/// out of the buffer (`count - capacity > sampleIndex`) the annotation
/// silently disappears.
@immutable
class MagneticAnnotation {
  const MagneticAnnotation({
    required this.sampleIndex,
    required this.builder,
    this.alignment = Alignment.bottomCenter,
  });

  /// Absolute sample index this marker is bound to. Compare against
  /// `buffer.count` to know whether it's currently visible.
  final int sampleIndex;
  final WidgetBuilder builder;
  final Alignment alignment;
}

/// Defines how to map an annotation's sample index to a horizontal
/// fraction of the trace. Matches the two stream modes.
enum AnnotationFlow { sweep, scroll }

/// Renders [annotations] on top of a stream trace.
///
/// Uses [CustomMultiChildLayout] with a [Listenable]-driven relayout, so
/// the widget tree is rebuilt only when the annotation *list* changes
/// (add / remove / clear). Per-frame ticking just re-runs the layout
/// delegate — no Widget allocations.
class MagneticAnnotationLayer extends StatefulWidget {
  const MagneticAnnotationLayer({
    super.key,
    required this.buffer,
    required this.annotations,
    required this.flow,
    this.padding = const EdgeInsets.all(8),
  });

  final StreamBuffer buffer;
  final List<MagneticAnnotation> annotations;
  final AnnotationFlow flow;
  final EdgeInsets padding;

  @override
  State<MagneticAnnotationLayer> createState() =>
      _MagneticAnnotationLayerState();
}

class _MagneticAnnotationLayerState extends State<MagneticAnnotationLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  void _onTick(Duration _) {
    final r = widget.buffer.revision;
    if (r == _lastRevision) return;
    _lastRevision = r;
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: ClipRect(
        child: CustomMultiChildLayout(
          delegate: _AnnotationLayout(
            buffer: widget.buffer,
            annotations: widget.annotations,
            flow: widget.flow,
            relayout: _frame,
          ),
          children: [
            for (var i = 0; i < widget.annotations.length; i++)
              LayoutId(
                id: i,
                child: Builder(builder: widget.annotations[i].builder),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnnotationLayout extends MultiChildLayoutDelegate {
  _AnnotationLayout({
    required this.buffer,
    required this.annotations,
    required this.flow,
    required Listenable relayout,
  }) : super(relayout: relayout);

  final StreamBuffer buffer;
  final List<MagneticAnnotation> annotations;
  final AnnotationFlow flow;

  @override
  void performLayout(Size size) {
    final cap = buffer.capacity;
    final count = buffer.count;
    final oldest = count - cap;
    final denom = cap > 1 ? (cap - 1).toDouble() : 1.0;

    for (var i = 0; i < annotations.length; i++) {
      if (!hasChild(i)) continue;
      final childSize = layoutChild(i, BoxConstraints.loose(size));
      final a = annotations[i];

      if (a.sampleIndex < oldest || a.sampleIndex >= count) {
        // Pin off-screen rather than skip — the child stays in the
        // element tree, so when it becomes visible again the same
        // RenderObject is reused.
        positionChild(i, Offset(-childSize.width - 64, 0));
        continue;
      }

      final fraction = flow == AnnotationFlow.sweep
          ? (a.sampleIndex % cap) / denom
          : (a.sampleIndex - oldest) / denom;
      final dx = fraction * size.width;
      final ax = (a.alignment.x + 1) * 0.5;
      final ay = (a.alignment.y + 1) * 0.5;
      final left = dx - childSize.width * ax;
      final top = (size.height - childSize.height) * ay;
      positionChild(i, Offset(left, top));
    }
  }

  @override
  bool shouldRelayout(covariant _AnnotationLayout old) =>
      annotations != old.annotations ||
      flow != old.flow ||
      buffer != old.buffer;
}

/// Backwards-compat shim. The layer now drives its own ticker, so wrapping
/// in [MagneticAnnotationListener] is a no-op — kept around for callers
/// upgrading from 1.0.0.
@Deprecated('MagneticAnnotationLayer drives its own ticker since 1.0.1.')
class MagneticAnnotationListener extends StatelessWidget {
  const MagneticAnnotationListener({
    super.key,
    required this.buffer,
    required this.child,
  });

  final StreamBuffer buffer;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
