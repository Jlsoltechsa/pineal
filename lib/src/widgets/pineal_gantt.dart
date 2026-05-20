import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../gantt/gantt_buffer.dart';
import '../gantt/gantt_render.dart';
import '../painters/text_cache.dart';

/// Top-level Gantt widget. One [RenderGantt] custom RenderBox under a
/// gesture detector for pan/zoom on the time axis and lane scroll on the
/// vertical axis. The buffer + slot index live on the State so we can
/// rebuild the index lazily when the dataset changes.
class PinealGantt extends StatefulWidget {
  const PinealGantt({
    super.key,
    required this.tasks,
    required this.viewport,
    required this.styleOf,
    this.slotMicros,
    this.laneHeight = 28,
    this.background = const Color(0xFFFFFFFF),
    this.gridLine = const Color(0xFFE0E0E0),
    this.onTaskTap,
  });

  final TaskBuffer tasks;
  final GanttViewport viewport;
  final GanttTaskStyleOf styleOf;

  /// Override the slot bucket size. Defaults to one tenth of the widest
  /// task's duration, which keeps average per-bucket population low.
  final double? slotMicros;
  final double laneHeight;
  final Color background;
  final Color gridLine;
  final void Function(int taskIndex)? onTaskTap;

  @override
  State<PinealGantt> createState() => _PinealGanttState();
}

class _PinealGanttState extends State<PinealGantt> {
  late SlotIndex _slotIndex;
  final TextCache _textCache = TextCache(maxEntries: 1024);
  double _laneScrollY = 0;

  @override
  void initState() {
    super.initState();
    _rebuildSlotIndex();
  }

  @override
  void didUpdateWidget(covariant PinealGantt old) {
    super.didUpdateWidget(old);
    if (old.tasks != widget.tasks ||
        old.tasks.revision != widget.tasks.revision ||
        old.slotMicros != widget.slotMicros) {
      _rebuildSlotIndex();
      // Re-clamp the lane scroll — if the new dataset is shorter than the
      // old one, otherwise the user lands in empty space below the last
      // lane until they scroll up.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final clamped = _clampLaneScroll(_laneScrollY);
        if (clamped != _laneScrollY) {
          setState(() => _laneScrollY = clamped);
        }
      });
    }
  }

  /// Clamps `next` to `[0, totalContentHeight - viewportHeight]` so the
  /// user can't scroll past the last lane into empty space. Falls back to
  /// the unbounded clamp when we don't yet know the viewport height (first
  /// frame).
  double _clampLaneScroll(double next) {
    final maxLane = widget.tasks.bounds().laneMax;
    final totalH = (maxLane + 1) * widget.laneHeight;
    final viewportH = context.size?.height ?? 0;
    if (viewportH <= 0) return next < 0 ? 0 : next;
    final upper = math.max(0.0, totalH - viewportH);
    return next.clamp(0.0, upper);
  }

  void _rebuildSlotIndex() {
    final slot = widget.slotMicros ?? _suggestSlotMicros();
    _slotIndex = SlotIndex.build(widget.tasks, slotMicros: slot);
  }

  /// Heuristic: average task duration × 4 keeps buckets around `~4` tasks
  /// each on uniform datasets. The cap protects against pathological
  /// inputs (single 10-year task that would otherwise demand 1 slot total).
  double _suggestSlotMicros() {
    if (widget.tasks.length == 0) return 86400 * 1e6; // 1 day fallback
    var sumDur = 0.0;
    for (var i = 0; i < widget.tasks.length; i++) {
      sumDur += widget.tasks.t2(i) - widget.tasks.t1(i);
    }
    final avg = sumDur / widget.tasks.length;
    return (avg * 4).clamp(60 * 1e6, 365 * 86400 * 1e6); // 1min..1yr
  }

  @override
  void dispose() {
    _textCache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          // Vertical wheel scrolls lanes; horizontal pans time.
          if (e.scrollDelta.dy != 0) {
            setState(() {
              _laneScrollY = _clampLaneScroll(_laneScrollY + e.scrollDelta.dy);
            });
          }
          if (e.scrollDelta.dx != 0) {
            final w = context.size?.width;
            if (w != null && w > 0) {
              widget.viewport.pan(e.scrollDelta.dx / w);
            }
          }
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) {},
        onScaleUpdate: (d) {
          if (d.scale != 1.0) {
            widget.viewport.zoom(1.0 / d.scale, anchorFrac: 0.5);
          }
          if (d.focalPointDelta != Offset.zero) {
            final w = context.size?.width ?? 1;
            widget.viewport.pan(-d.focalPointDelta.dx / w);
            setState(() {
              _laneScrollY =
                  _clampLaneScroll(_laneScrollY - d.focalPointDelta.dy);
            });
          }
        },
        child: _GanttHost(
          tasks: widget.tasks,
          slotIndex: _slotIndex,
          viewport: widget.viewport,
          styleOf: widget.styleOf,
          textCache: _textCache,
          laneHeight: widget.laneHeight,
          laneScrollY: _laneScrollY,
          background: widget.background,
          gridLine: widget.gridLine,
          onTaskTap: widget.onTaskTap,
        ),
      ),
    );
  }
}

class _GanttHost extends LeafRenderObjectWidget {
  const _GanttHost({
    required this.tasks,
    required this.slotIndex,
    required this.viewport,
    required this.styleOf,
    required this.textCache,
    required this.laneHeight,
    required this.laneScrollY,
    required this.background,
    required this.gridLine,
    required this.onTaskTap,
  });

  final TaskBuffer tasks;
  final SlotIndex slotIndex;
  final GanttViewport viewport;
  final GanttTaskStyleOf styleOf;
  final TextCache textCache;
  final double laneHeight;
  final double laneScrollY;
  final Color background;
  final Color gridLine;
  final void Function(int)? onTaskTap;

  @override
  RenderGantt createRenderObject(BuildContext context) {
    return RenderGantt(
      tasks: tasks,
      slotIndex: slotIndex,
      viewport: viewport,
      styleOf: styleOf,
      textCache: textCache,
      laneHeight: laneHeight,
      laneScrollY: laneScrollY,
      background: background,
      gridLine: gridLine,
      onTap: onTaskTap,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderGantt renderObject) {
    renderObject
      ..tasks = tasks
      ..slotIndex = slotIndex
      ..viewport = viewport
      ..styleOf = styleOf
      ..laneHeight = laneHeight
      ..laneScrollY = laneScrollY
      ..background = background
      ..gridLine = gridLine
      ..onTap = onTaskTap;
  }
}
