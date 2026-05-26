/// Pineal gantt — virtual chronological scroll over a `Float64List` task
/// buffer. The `RenderBox` paints only tasks whose `[t1, t2]` intersects
/// the time viewport, with a `SlotIndex` providing `O(1 + k)` time
/// queries via uniform bucketing along the time axis.
///
/// Same buffer/painter pattern the cartesian and grid modules use — no
/// per-task widget, hit-testing routes through the same slot index, labels
/// share the LRU `TextCache` so a 1000-task viewport runs `Paragraph.layout`
/// once per unique label rather than once per bar per frame.
library;

export 'core.dart';

export 'src/gantt/gantt_buffer.dart';
export 'src/gantt/gantt_render.dart';

export 'src/widgets/pineal_gantt.dart';
