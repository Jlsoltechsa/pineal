import 'dart:convert';

import 'column.dart';
import 'data_source.dart';
import 'grid_controller.dart';

/// Async exporters for the grid's currently-displayed view (filter + sort
/// already applied, since iteration goes through `source.valueAt(row, …)`
/// which honors `_displayOrder`). Both methods yield to the event loop
/// every [chunkSize] rows so a 1M-row export doesn't freeze the UI.
///
/// Output is returned as a `String` so the caller decides what to do with
/// it — save to disk via `file_selector`, push to a share sheet, copy to
/// the clipboard, etc. Pineal doesn't pull in a file I/O dependency.
class GridExport {
  GridExport._();

  static const int _defaultChunkSize = 1024;

  /// RFC 4180-compatible CSV. Quotes any field that contains the [separator],
  /// a quote, CR or LF, and doubles embedded quotes. Values are produced via
  /// `column.format(value)` so what the user sees in the grid is what lands
  /// in the file.
  ///
  /// Pass [selection] to export only that rectangular sub-range — the
  /// columns spanned by `anchor` and `focus`, and the rows between
  /// `firstRow` and `lastRow` inclusive. When `null`, every row × every
  /// column in [columns] is exported.
  static Future<String> toCsv({
    required List<GridColumn> columns,
    required GridDataSource source,
    GridSelection? selection,
    String separator = ',',
    String lineEnding = '\r\n',
    bool includeHeader = true,
    int chunkSize = _defaultChunkSize,
  }) async {
    final (activeCols, rowStart, rowEnd) =
        _resolveScope(columns, source, selection);
    final buf = StringBuffer();
    if (includeHeader) {
      buf.write(activeCols
          .map((c) => _csvEscape(c.header, separator))
          .join(separator));
      buf.write(lineEnding);
    }
    var processed = 0;
    for (var r = rowStart; r <= rowEnd; r++) {
      for (var i = 0; i < activeCols.length; i++) {
        if (i > 0) buf.write(separator);
        final col = activeCols[i];
        buf.write(_csvEscape(col.format(source.valueAt(r, col.id)), separator));
      }
      buf.write(lineEnding);
      processed++;
      if (processed >= chunkSize) {
        processed = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    return buf.toString();
  }

  /// JSON array of objects keyed by `column.id`. Type fidelity is preserved
  /// where `jsonEncode` knows how: `num` → number, `bool` → bool, `null` →
  /// null, `String` → string, `DateTime` → ISO 8601 string. Anything else
  /// falls back to `toString()`.
  ///
  /// [pretty] toggles two-space indentation. Off by default — round-trip
  /// fidelity matters more than human-readability for export, and pretty
  /// JSON inflates payload size 2-3×.
  static Future<String> toJson({
    required List<GridColumn> columns,
    required GridDataSource source,
    GridSelection? selection,
    bool pretty = false,
    int chunkSize = _defaultChunkSize,
  }) async {
    final (activeCols, rowStart, rowEnd) =
        _resolveScope(columns, source, selection);
    final rows = <Map<String, Object?>>[];
    var processed = 0;
    for (var r = rowStart; r <= rowEnd; r++) {
      final row = <String, Object?>{};
      for (final col in activeCols) {
        row[col.id] = _jsonSafe(source.valueAt(r, col.id));
      }
      rows.add(row);
      processed++;
      if (processed >= chunkSize) {
        processed = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    final encoder = pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    return encoder.convert(rows);
  }

  /// Narrows [columns] and the row range to a [GridSelection] when present.
  /// Falls back to the full view when [selection] is null or its column IDs
  /// can't be resolved against [columns].
  static (List<GridColumn>, int, int) _resolveScope(
      List<GridColumn> columns, GridDataSource source,
      GridSelection? selection) {
    if (selection == null) {
      return (columns, 0, source.rowCount - 1);
    }
    final aIdx = columns.indexWhere((c) => c.id == selection.anchor.columnId);
    final fIdx = columns.indexWhere((c) => c.id == selection.focus.columnId);
    if (aIdx < 0 || fIdx < 0) {
      return (columns, 0, source.rowCount - 1);
    }
    final lo = aIdx < fIdx ? aIdx : fIdx;
    final hi = aIdx > fIdx ? aIdx : fIdx;
    final activeCols = columns.sublist(lo, hi + 1);
    return (activeCols, selection.firstRow, selection.lastRow);
  }

  static String _csvEscape(String field, String separator) {
    if (field.isEmpty) return '';
    final needsQuote = field.contains(separator) ||
        field.contains('"') ||
        field.contains('\r') ||
        field.contains('\n');
    if (!needsQuote) return field;
    return '"${field.replaceAll('"', '""')}"';
  }

  /// Map a Dart value to something `jsonEncode` can serialize without
  /// throwing. `num`/`bool`/`null`/`String` pass through; `DateTime` goes
  /// to ISO 8601; everything else falls back to `toString()`.
  static Object? _jsonSafe(Object? value) {
    if (value == null) return null;
    if (value is num || value is bool || value is String) return value;
    if (value is DateTime) return value.toIso8601String();
    return value.toString();
  }
}
