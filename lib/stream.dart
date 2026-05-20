/// Pineal stream — high-frequency telemetry / oscilloscope rendering.
///
/// Built around a fixed-capacity [StreamBuffer] (circular ring on a single
/// [Float32List]) and a [PinealStream] widget that draws the buffer at
/// every frame without per-frame allocations.
library pineal.stream;

export 'core.dart';

export 'src/stream/stream_buffer.dart';
export 'src/stream/stream_feed.dart';
export 'src/stream/stream_downsample.dart';
export 'src/stream/pineal_stream.dart';
