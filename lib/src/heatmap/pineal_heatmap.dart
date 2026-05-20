import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'color_ramp.dart';
import 'heatmap_data.dart';

/// Renders a [HeatmapData] matrix as a colored bitmap.
///
/// Two render paths:
///
/// 1. **Default (CPU color mapping)** — every cell is mapped through
///    [ramp] into RGBA bytes once per data revision, uploaded as a
///    `ui.Image`, and drawn as a single quad. Encoding runs on a worker
///    isolate (`compute()`) above [asyncThresholdCells] so the UI thread
///    stays free.
///
/// 2. **Custom shader** — when [customShader] is provided, the matrix is
///    encoded as a **24-bit packed value texture**: each cell's normalised
///    value `t ∈ [0, 1]` is split across the R / G / B channels (R = high
///    byte, G = mid, B = low; A = 255). The shader receives this as
///    sampler 0 and decodes the value back to a float in GLSL:
///
///    ```glsl
///    float decodeValue(vec4 s) {
///      return s.r + s.g / 256.0 + s.b / 65536.0; // ≈ 24-bit precision
///    }
///    ```
///
///    Use `FilterQuality.none` (the default) so neighbouring cells aren't
///    bilinearly interpolated — that would scramble the packed bits.
class PinealHeatmap extends StatefulWidget {
  const PinealHeatmap({
    super.key,
    required this.data,
    this.ramp,
    this.minOverride,
    this.maxOverride,
    this.filter = FilterQuality.none,
    this.customShader,
    this.asyncThresholdCells = 65536,
  });

  final HeatmapData data;

  /// Color ramp used when [customShader] is null. Defaults to
  /// [ColorRamp.viridis].
  final ColorRamp? ramp;

  /// Domain overrides — useful for sharing a scale across multiple heatmaps.
  /// When null, `data.minValue` / `data.maxValue` are used.
  final double? minOverride;
  final double? maxOverride;

  /// Sampling when the bitmap is scaled to fit the widget. `none` keeps the
  /// blocky look; `low`/`medium` smooth between cells.
  final FilterQuality filter;

  /// When provided, replaces the CPU color-mapping path. The painter binds
  /// the encoded value texture as `setImageSampler(0, …)` before drawing.
  /// Configure your own uniforms on this shader before passing it in.
  final ui.FragmentShader? customShader;

  /// Above this cell count the encoding runs on a worker isolate via
  /// `compute()`. Below it, we stay on the main isolate (isolate spawn
  /// overhead would dominate for small heatmaps).
  final int asyncThresholdCells;

  @override
  State<PinealHeatmap> createState() => _PinealHeatmapState();
}

class _PinealHeatmapState extends State<PinealHeatmap> {
  ui.Image? _image;
  Object? _lastKey;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(covariant PinealHeatmap old) {
    super.didUpdateWidget(old);
    if (_keyOf(widget) != _lastKey) {
      _rebuild();
    }
  }

  Object _keyOf(PinealHeatmap w) => Object.hash(
        identityHashCode(w.data),
        identityHashCode(w.ramp),
        identityHashCode(w.customShader),
        w.minOverride,
        w.maxOverride,
      );

  Future<void> _rebuild() async {
    final w = widget;
    _lastKey = _keyOf(w);
    final image = await _buildImage(w);
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  static Future<ui.Image> _buildImage(PinealHeatmap w) async {
    final data = w.data;
    final mn = w.minOverride ?? data.minValue;
    final mx = w.maxOverride ?? data.maxValue;

    final useShader = w.customShader != null;
    final cells = data.width * data.height;

    // Encoding: either CPU-mapped RGBA via ColorRamp, or single-channel
    // value bytes for the shader to color in GLSL.
    final Uint8List pixels;
    if (useShader) {
      final args = _ValueEncodeArgs(data.values, mn, mx);
      pixels = cells > w.asyncThresholdCells
          ? await compute(_encodeValueIsolate, args)
          : _encodeValue(args);
    } else {
      final ramp = w.ramp ?? ColorRamp.viridis();
      final args = _RampEncodeArgs(data.values, ramp.table, ramp.tableSize, mn, mx);
      pixels = cells > w.asyncThresholdCells
          ? await compute(_encodeRampIsolate, args)
          : _encodeRamp(args);
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: data.width,
      height: data.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    descriptor.dispose();
    buffer.dispose();
    codec.dispose();
    return frame.image;
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return const SizedBox.expand();
    return RepaintBoundary(
      child: CustomPaint(
        painter: _HeatmapPainter(
          image: img,
          filter: widget.filter,
          shader: widget.customShader,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _RampEncodeArgs {
  const _RampEncodeArgs(
      this.values, this.rampTable, this.rampSize, this.minValue, this.maxValue);
  final Float32List values;
  final Uint8List rampTable;
  final int rampSize;
  final double minValue;
  final double maxValue;
}

class _ValueEncodeArgs {
  const _ValueEncodeArgs(this.values, this.minValue, this.maxValue);
  final Float32List values;
  final double minValue;
  final double maxValue;
}

Uint8List _encodeRampIsolate(_RampEncodeArgs a) => _encodeRamp(a);
Uint8List _encodeValueIsolate(_ValueEncodeArgs a) => _encodeValue(a);

Uint8List _encodeRamp(_RampEncodeArgs a) {
  final values = a.values;
  final out = Uint8List(values.length * 4);
  final span = a.maxValue - a.minValue;
  final inv = span == 0 ? 0.0 : 1.0 / span;
  final lastIdx = a.rampSize - 1;
  for (var i = 0; i < values.length; i++) {
    final v = values[i];
    if (!v.isFinite) {
      // alpha left at 0 = transparent.
      continue;
    }
    var t = (v - a.minValue) * inv;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final idx = (t * lastIdx).floor() * 4;
    final o = i * 4;
    out[o] = a.rampTable[idx];
    out[o + 1] = a.rampTable[idx + 1];
    out[o + 2] = a.rampTable[idx + 2];
    out[o + 3] = a.rampTable[idx + 3];
  }
  return out;
}

Uint8List _encodeValue(_ValueEncodeArgs a) {
  final values = a.values;
  final out = Uint8List(values.length * 4);
  final span = a.maxValue - a.minValue;
  final inv = span == 0 ? 0.0 : 1.0 / span;
  for (var i = 0; i < values.length; i++) {
    final v = values[i];
    if (!v.isFinite) continue;
    var t = (v - a.minValue) * inv;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    // Pack a normalised value into 24 bits across R / G / B. Decoded in
    // GLSL as `s.r + s.g/256 + s.b/65536`, giving ≈ 1/16M precision —
    // plenty for almost any visualization at sane domain spans.
    final scaled = (t * 0xFFFFFF).round();
    final o = i * 4;
    out[o] = (scaled >> 16) & 0xFF;
    out[o + 1] = (scaled >> 8) & 0xFF;
    out[o + 2] = scaled & 0xFF;
    out[o + 3] = 255;
  }
  return out;
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.image,
    required this.filter,
    required this.shader,
  });
  final ui.Image image;
  final FilterQuality filter;
  final ui.FragmentShader? shader;

  @override
  void paint(Canvas canvas, Size size) {
    if (shader != null) {
      shader!.setImageSampler(0, image);
      canvas.drawRect(
        Offset.zero & size,
        Paint()..shader = shader,
      );
      return;
    }
    final src = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Offset.zero & size;
    final paint = Paint()..filterQuality = filter;
    canvas.drawImageRect(image, src, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) {
    return old.image != image ||
        old.filter != filter ||
        old.shader != shader;
  }
}
