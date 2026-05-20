import 'dart:typed_data';
import 'dart:ui';

import '../core/pineal_core.dart';
import '../data/data_buffer.dart';
import '../data/lttb.dart';
import '../series/area_series.dart';
import '../series/bar_series.dart';
import '../series/line_series.dart';
import '../series/series.dart';
import 'export_profile.dart';

/// Pure-Dart SVG emitter for the cartesian family.
///
/// Walks the series list and produces vector elements (polyline / rect /
/// path) sized to the [ExportProfile]. Decimation is medium-aware: a print
/// profile at 300 DPI keeps roughly 3× the vertex budget of a 96 DPI
/// screen profile, so the same series renders crisp on paper without
/// inflating the screen export.
class SvgExporter {
  /// Exports a multi-axis cartesian chart as a self-contained SVG string.
  /// The returned text starts with `<?xml …?>` and is ready to write to
  /// disk or hand off to a PDF/PNG converter.
  static String exportCartesian({
    required List<Series> series,
    required List<YAxisSpec> yAxes,
    ({double min, double max})? xRange,
    required ExportProfile profile,
    String background = '#FFFFFF',
    double padding = 48,
    int axisTickTarget = 6,
    String fontFamily = 'sans-serif',
  }) {
    final w = profile.pixelWidth;
    final h = profile.pixelHeight;

    final xWin = xRange ?? _unionX(series);
    final firstAxis = yAxes.isNotEmpty
        ? yAxes.first
        : const YAxisSpec(id: 'y', min: 0, max: 1);
    final firstY = (min: firstAxis.min, max: firstAxis.max);

    final plot = Rect.fromLTWH(
      padding,
      padding * 0.5,
      w - padding * 1.5,
      h - padding,
    );

    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..write('<svg xmlns="http://www.w3.org/2000/svg" ')
      ..write('viewBox="0 0 ${w.toStringAsFixed(0)} ${h.toStringAsFixed(0)}" ')
      ..writeln('font-family="$fontFamily" font-size="11">')
      ..writeln(
          '<rect width="${w.toStringAsFixed(0)}" height="${h.toStringAsFixed(0)}" fill="$background"/>');

    _emitGrid(buf, plot, xWin, firstY, axisTickTarget);

    for (final s in series) {
      final yAxis = yAxes.firstWhere(
        (a) => a.id == s.yAxisId,
        orElse: () => firstAxis,
      );
      final yWin = (min: yAxis.min, max: yAxis.max);
      if (s is LineSeries) {
        _emitLine(buf, s, plot, xWin, yWin, profile);
      } else if (s is AreaSeries) {
        _emitArea(buf, s, plot, xWin, yWin, profile);
      } else if (s is BarSeries) {
        _emitBar(buf, s, plot, xWin, yWin, profile);
      }
    }

    _emitAxes(buf, plot, xWin, firstY, axisTickTarget);

    buf.writeln('</svg>');
    return buf.toString();
  }

  // ───────────────────────────── helpers ─────────────────────────────

  static ({double min, double max}) _unionX(List<Series> series) {
    if (series.isEmpty) return (min: 0.0, max: 1.0);
    var lo = series.first.data.xMin;
    var hi = series.first.data.xMax;
    for (final s in series.skip(1)) {
      if (s.data.xMin < lo) lo = s.data.xMin;
      if (s.data.xMax > hi) hi = s.data.xMax;
    }
    if (lo == hi) hi = lo + 1;
    return (min: lo, max: hi);
  }

  static String _hex(Color c) {
    final v = c.toARGB32();
    final r = (v >> 16) & 0xFF;
    final g = (v >> 8) & 0xFF;
    final b = v & 0xFF;
    String pad(int x) => x.toRadixString(16).padLeft(2, '0');
    return '#${pad(r)}${pad(g)}${pad(b)}';
  }

  static double _alpha(Color c) => ((c.toARGB32() >> 24) & 0xFF) / 255.0;

  /// Resamples a series down to `profile.targetVertices` via LTTB, then
  /// projects to plot pixel coords. Returns interleaved `[x, y, x, y, …]`.
  static Float32List _project(
    DataBuffer data,
    Rect plot,
    ({double min, double max}) xWin,
    ({double min, double max}) yWin,
    ExportProfile profile,
  ) {
    final start = _lowerBound(data, xWin.min);
    final end = _lowerBound(data, xWin.max);
    final hi = (end + 1).clamp(0, data.length);
    final lo = start.clamp(0, data.length);
    final visible = hi - lo;
    if (visible <= 0) return Float32List(0);

    final target = profile.targetVertices;
    final indices = visible > target
        ? LTTB.indicesInRange(data, lo, hi, target)
        : Int32List.fromList(List.generate(visible, (i) => lo + i));

    final out = Float32List(indices.length * 2);
    final xSpan = xWin.max - xWin.min;
    final ySpan = yWin.max - yWin.min;
    final xScale = xSpan == 0 ? 0 : plot.width / xSpan;
    final yScale = ySpan == 0 ? 0 : plot.height / ySpan;

    for (var k = 0; k < indices.length; k++) {
      final i = indices[k];
      out[k * 2] = plot.left + (data.xAt(i) - xWin.min) * xScale;
      out[k * 2 + 1] = plot.bottom - (data.yAt(i) - yWin.min) * yScale;
    }
    return out;
  }

  static int _lowerBound(DataBuffer data, double target) {
    var lo = 0;
    var hi = data.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (data.xAt(mid) < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static void _emitLine(
    StringBuffer buf,
    LineSeries s,
    Rect plot,
    ({double min, double max}) xWin,
    ({double min, double max}) yWin,
    ExportProfile profile,
  ) {
    final pts = _project(s.data, plot, xWin, yWin, profile);
    if (pts.isEmpty) return;
    buf
      ..write('<polyline fill="none" stroke="${_hex(s.color)}" ')
      ..write('stroke-opacity="${_alpha(s.color).toStringAsFixed(3)}" ')
      ..write('stroke-width="${s.strokeWidth}" stroke-linejoin="round" points="');
    for (var k = 0; k < pts.length; k += 2) {
      if (k > 0) buf.write(' ');
      buf
        ..write(pts[k].toStringAsFixed(2))
        ..write(',')
        ..write(pts[k + 1].toStringAsFixed(2));
    }
    buf.writeln('"/>');
  }

  static void _emitArea(
    StringBuffer buf,
    AreaSeries s,
    Rect plot,
    ({double min, double max}) xWin,
    ({double min, double max}) yWin,
    ExportProfile profile,
  ) {
    final pts = _project(s.data, plot, xWin, yWin, profile);
    if (pts.length < 4) return;

    final ySpan = yWin.max - yWin.min;
    final baselinePx = plot.bottom -
        (s.baseline - yWin.min) * (ySpan == 0 ? 0 : plot.height / ySpan);

    buf.write('<path d="M ');
    buf.write(pts[0].toStringAsFixed(2));
    buf.write(',');
    buf.write(baselinePx.toStringAsFixed(2));
    buf.write(' L ');
    for (var k = 0; k < pts.length; k += 2) {
      if (k > 0) buf.write(' L ');
      buf.write(pts[k].toStringAsFixed(2));
      buf.write(',');
      buf.write(pts[k + 1].toStringAsFixed(2));
    }
    buf.write(' L ');
    buf.write(pts[pts.length - 2].toStringAsFixed(2));
    buf.write(',');
    buf.write(baselinePx.toStringAsFixed(2));
    buf.write(' Z" ');
    buf.write('fill="${_hex(s.fillColor)}" ');
    buf.write('fill-opacity="${_alpha(s.fillColor).toStringAsFixed(3)}" ');
    if (s.strokeWidth > 0) {
      buf.write('stroke="${_hex(s.strokeColor)}" ');
      buf.write(
          'stroke-opacity="${_alpha(s.strokeColor).toStringAsFixed(3)}" ');
      buf.write('stroke-width="${s.strokeWidth}" ');
    } else {
      buf.write('stroke="none" ');
    }
    buf.writeln('/>');
  }

  static void _emitBar(
    StringBuffer buf,
    BarSeries s,
    Rect plot,
    ({double min, double max}) xWin,
    ({double min, double max}) yWin,
    ExportProfile profile,
  ) {
    final pts = _project(s.data, plot, xWin, yWin, profile);
    if (pts.isEmpty) return;
    final ySpan = yWin.max - yWin.min;
    final baselinePx = plot.bottom -
        (s.baseline - yWin.min) * (ySpan == 0 ? 0 : plot.height / ySpan);

    final n = pts.length ~/ 2;
    final spacing = n > 1 ? (pts[2] - pts[0]) : 8.0;
    final barW = spacing * s.widthFactor;

    final color = _hex(s.color);
    final alpha = _alpha(s.color).toStringAsFixed(3);
    buf.writeln('<g fill="$color" fill-opacity="$alpha">');
    for (var k = 0; k < n; k++) {
      final cx = pts[k * 2];
      final y = pts[k * 2 + 1];
      final top = y < baselinePx ? y : baselinePx;
      final height = (baselinePx - y).abs();
      final x = cx - barW * 0.5;
      buf
        ..write('<rect x="')
        ..write(x.toStringAsFixed(2))
        ..write('" y="')
        ..write(top.toStringAsFixed(2))
        ..write('" width="')
        ..write(barW.toStringAsFixed(2))
        ..write('" height="')
        ..write(height.toStringAsFixed(2))
        ..writeln('"/>');
    }
    buf.writeln('</g>');
  }

  static void _emitGrid(
    StringBuffer buf,
    Rect plot,
    ({double min, double max}) xWin,
    ({double min, double max}) yWin,
    int target,
  ) {
    final xTicks = _niceTicks(xWin.min, xWin.max, target);
    final yTicks = _niceTicks(yWin.min, yWin.max, target);
    buf.writeln(
        '<g stroke="#E6EAEE" stroke-width="0.5" stroke-opacity="0.8">');
    for (final t in xTicks) {
      final px = plot.left +
          (t - xWin.min) / (xWin.max - xWin.min) * plot.width;
      buf.writeln(
          '<line x1="${px.toStringAsFixed(2)}" y1="${plot.top.toStringAsFixed(2)}" x2="${px.toStringAsFixed(2)}" y2="${plot.bottom.toStringAsFixed(2)}"/>');
    }
    for (final t in yTicks) {
      final py = plot.bottom -
          (t - yWin.min) / (yWin.max - yWin.min) * plot.height;
      buf.writeln(
          '<line x1="${plot.left.toStringAsFixed(2)}" y1="${py.toStringAsFixed(2)}" x2="${plot.right.toStringAsFixed(2)}" y2="${py.toStringAsFixed(2)}"/>');
    }
    buf.writeln('</g>');
  }

  static void _emitAxes(
    StringBuffer buf,
    Rect plot,
    ({double min, double max}) xWin,
    ({double min, double max}) yWin,
    int target,
  ) {
    buf.writeln('<g stroke="#444444" fill="#333333" stroke-width="1">');
    buf.writeln(
        '<line x1="${plot.left.toStringAsFixed(2)}" y1="${plot.bottom.toStringAsFixed(2)}" x2="${plot.right.toStringAsFixed(2)}" y2="${plot.bottom.toStringAsFixed(2)}"/>');
    buf.writeln(
        '<line x1="${plot.left.toStringAsFixed(2)}" y1="${plot.top.toStringAsFixed(2)}" x2="${plot.left.toStringAsFixed(2)}" y2="${plot.bottom.toStringAsFixed(2)}"/>');

    final xTicks = _niceTicks(xWin.min, xWin.max, target);
    for (final t in xTicks) {
      final px = plot.left +
          (t - xWin.min) / (xWin.max - xWin.min) * plot.width;
      buf.writeln(
          '<line x1="${px.toStringAsFixed(2)}" y1="${plot.bottom.toStringAsFixed(2)}" x2="${px.toStringAsFixed(2)}" y2="${(plot.bottom + 4).toStringAsFixed(2)}"/>');
      buf.writeln(
          '<text x="${px.toStringAsFixed(2)}" y="${(plot.bottom + 16).toStringAsFixed(2)}" text-anchor="middle" stroke="none">${_fmt(t)}</text>');
    }
    final yTicks = _niceTicks(yWin.min, yWin.max, target);
    for (final t in yTicks) {
      final py = plot.bottom -
          (t - yWin.min) / (yWin.max - yWin.min) * plot.height;
      buf.writeln(
          '<line x1="${(plot.left - 4).toStringAsFixed(2)}" y1="${py.toStringAsFixed(2)}" x2="${plot.left.toStringAsFixed(2)}" y2="${py.toStringAsFixed(2)}"/>');
      buf.writeln(
          '<text x="${(plot.left - 6).toStringAsFixed(2)}" y="${(py + 4).toStringAsFixed(2)}" text-anchor="end" stroke="none">${_fmt(t)}</text>');
    }
    buf.writeln('</g>');
  }

  static List<double> _niceTicks(double min, double max, int target) {
    if (min == max) return [min];
    final span = (max - min).abs();
    final raw = span / target;
    // Simple "nice step" pick: 1, 2, 5 × 10^k.
    final magnitude = _pow10(raw <= 0 ? 1 : raw);
    final frac = raw / magnitude;
    final niceFrac = frac < 1.5
        ? 1.0
        : frac < 3
            ? 2.0
            : frac < 7
                ? 5.0
                : 10.0;
    final step = niceFrac * magnitude;
    final first = (min / step).floor() * step;
    final out = <double>[];
    for (var v = first; v <= max + step * 0.5; v += step) {
      if (v >= min - step * 0.5) out.add(v);
      if (out.length > target * 4) break;
    }
    return out;
  }

  static double _pow10(double v) {
    if (v <= 0) return 1;
    var p = 1.0;
    if (v >= 1) {
      while (p * 10 <= v) {
        p *= 10;
      }
    } else {
      while (p > v) {
        p /= 10;
      }
    }
    return p;
  }

  static String _fmt(double v) {
    final abs = v.abs();
    if (abs != 0 && (abs < 1e-3 || abs >= 1e6)) {
      return v.toStringAsExponential(2);
    }
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }
}
