import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'column.dart';
import 'data_source.dart';
import 'grid_controller.dart';

/// Excel-style filter overlay opened by right-clicking on a column header.
///
/// Pattern: a search box at the top filters the visible options *within the
/// popup* (it doesn't apply a TextFilter to the grid); below it sits a
/// scrollable checklist of unique values. Apply commits a [ValueSetFilter]
/// with the checked subset. Clear removes the column's filter entirely.
///
/// For columns whose unique-value count exceeds the source's `uniqueValues`
/// limit, a footer notes that the list was truncated — power users who need
/// narrower targeting can still install a [TextFilter] programmatically via
/// `controller.setFilter(id, TextFilter(...))`.
class FilterPopup extends StatefulWidget {
  const FilterPopup({
    super.key,
    required this.column,
    required this.controller,
    required this.position,
    required this.viewportSize,
    required this.onClose,
  });

  final GridColumn column;
  final GridController controller;
  final Offset position;
  final Size viewportSize;
  final VoidCallback onClose;

  @override
  State<FilterPopup> createState() => _FilterPopupState();
}

class _FilterPopupState extends State<FilterPopup> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // Numeric-range branch state.
  final TextEditingController _minCtrl = TextEditingController();
  final TextEditingController _maxCtrl = TextEditingController();
  final FocusNode _minFocus = FocusNode();

  static const double _width = 260;
  static const double _height = 360;
  static const int _uniqueValueLimit = 1000;

  late List<Object?> _allValues;
  late Set<Object?> _excluded;
  bool _truncated = false;
  _FilterType _type = _FilterType.categorical;
  num? _columnMin;
  num? _columnMax;
  DateTime? _dateMin;
  DateTime? _dateMax;

  @override
  void initState() {
    super.initState();
    _loadValues();
    _detectColumnType();
    _seedFromExistingFilter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_type == _FilterType.numeric || _type == _FilterType.date) {
        _minFocus.requestFocus();
      } else {
        _searchFocus.requestFocus();
      }
    });
    _search.addListener(_onSearchChange);
    // Keep the slider in sync with manual edits to the text fields.
    _minCtrl.addListener(_onRangeFieldsChange);
    _maxCtrl.addListener(_onRangeFieldsChange);
  }

  void _onRangeFieldsChange() {
    // setState so the slider rebuilds with the parsed values. Cheap enough
    // — only one popup is alive at a time.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChange);
    _minCtrl.removeListener(_onRangeFieldsChange);
    _maxCtrl.removeListener(_onRangeFieldsChange);
    _search.dispose();
    _searchFocus.dispose();
    _minCtrl.dispose();
    _maxCtrl.dispose();
    _minFocus.dispose();
    super.dispose();
  }

  /// Picks a popup body based on the column's runtime value type. If every
  /// non-null sampled value is a `num` → numeric range; if every non-null
  /// is a `DateTime` → date range; otherwise → categorical checklist.
  /// Fully-null columns fall back to categorical so the user still gets a
  /// usable popup.
  void _detectColumnType() {
    var sawAny = false;
    var allNum = true;
    var allDate = true;
    num? nlo;
    num? nhi;
    DateTime? dlo;
    DateTime? dhi;
    for (final v in _allValues) {
      if (v == null) continue;
      sawAny = true;
      if (v is num) {
        if (nlo == null || v < nlo) nlo = v;
        if (nhi == null || v > nhi) nhi = v;
        allDate = false;
      } else if (v is DateTime) {
        if (dlo == null || v.isBefore(dlo)) dlo = v;
        if (dhi == null || v.isAfter(dhi)) dhi = v;
        allNum = false;
      } else {
        allNum = false;
        allDate = false;
      }
    }
    if (sawAny && allNum) {
      _type = _FilterType.numeric;
      _columnMin = nlo;
      _columnMax = nhi;
    } else if (sawAny && allDate) {
      _type = _FilterType.date;
      _dateMin = dlo;
      _dateMax = dhi;
    } else {
      _type = _FilterType.categorical;
    }
  }

  void _onSearchChange() => setState(() {});

  void _loadValues() {
    final raw = widget.controller.source
        .uniqueValues(widget.column.id, limit: _uniqueValueLimit);
    _truncated = raw.length >= _uniqueValueLimit;
    final values = List<Object?>.from(raw);
    // Stable sort by formatted text so the list is browseable. Nulls float
    // to the top so "(empty)" stays in a predictable spot.
    values.sort((a, b) {
      if (a == null && b == null) return 0;
      if (a == null) return -1;
      if (b == null) return 1;
      return widget.column.format(a).compareTo(widget.column.format(b));
    });
    _allValues = values;
  }

  void _seedFromExistingFilter() {
    final existing = widget.controller.filters[widget.column.id];
    if (existing is ValueSetFilter) {
      final allowed = existing.allowed;
      _excluded = _allValues.where((v) => !allowed.contains(v)).toSet();
    } else {
      _excluded = <Object?>{};
    }
    if (existing is NumericRangeFilter) {
      if (existing.min != null) _minCtrl.text = _formatNum(existing.min!);
      if (existing.max != null) _maxCtrl.text = _formatNum(existing.max!);
    }
    if (existing is DateRangeFilter) {
      if (existing.min != null) _minCtrl.text = _formatDate(existing.min!);
      if (existing.max != null) _maxCtrl.text = _formatDate(existing.max!);
    }
  }

  String _formatDate(DateTime d) =>
      // ISO 8601 date-only — the format we accept on input too.
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _formatNum(num v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toString();

  String _labelFor(Object? value) {
    if (value == null) return '(empty)';
    final s = widget.column.format(value);
    return s.isEmpty ? '(empty)' : s;
  }

  List<Object?> _visibleValues() {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _allValues;
    return _allValues
        .where((v) => _labelFor(v).toLowerCase().contains(q))
        .toList();
  }

  bool _isChecked(Object? value) => !_excluded.contains(value);

  void _toggle(Object? value) {
    setState(() {
      if (_excluded.contains(value)) {
        _excluded.remove(value);
      } else {
        _excluded.add(value);
      }
    });
  }

  void _apply() {
    if (_type == _FilterType.numeric) {
      final lo = num.tryParse(_minCtrl.text.trim());
      final hi = num.tryParse(_maxCtrl.text.trim());
      if (lo == null && hi == null) {
        widget.controller.setFilter(widget.column.id, null);
      } else {
        widget.controller.setFilter(
            widget.column.id, NumericRangeFilter(min: lo, max: hi));
      }
      widget.onClose();
      return;
    }
    if (_type == _FilterType.date) {
      final lo = DateTime.tryParse(_minCtrl.text.trim());
      final hi = DateTime.tryParse(_maxCtrl.text.trim());
      if (lo == null && hi == null) {
        widget.controller.setFilter(widget.column.id, null);
      } else {
        widget.controller
            .setFilter(widget.column.id, DateRangeFilter(min: lo, max: hi));
      }
      widget.onClose();
      return;
    }
    if (_excluded.isEmpty) {
      widget.controller.setFilter(widget.column.id, null);
    } else if (_excluded.length == _allValues.length) {
      widget.controller.setFilter(widget.column.id, ValueSetFilter(<Object?>{}));
    } else {
      final allowed = _allValues.where((v) => !_excluded.contains(v)).toSet();
      widget.controller.setFilter(widget.column.id, ValueSetFilter(allowed));
    }
    widget.onClose();
  }

  void _clear() {
    widget.controller.setFilter(widget.column.id, null);
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final height = switch (_type) {
      _FilterType.numeric => 296.0,
      _FilterType.date => 268.0,
      _FilterType.categorical => _height,
    };
    final left = widget.position.dx
        .clamp(0.0, (widget.viewportSize.width - _width).clamp(0.0, double.infinity));
    final top = widget.position.dy
        .clamp(0.0, (widget.viewportSize.height - height).clamp(0.0, double.infinity));

    return Positioned(
      left: left,
      top: top,
      width: _width,
      height: height,
      child: TapRegion(
        onTapOutside: (_) => widget.onClose(),
        // Wraps the whole popup so Esc dismisses no matter which child
        // (search field, list, min/max field) currently owns the inner
        // focus. Tab uses Flutter's default focus traversal between the
        // popup's TextFields and the actionable buttons.
        child: Focus(
          autofocus: false,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape) {
              widget.onClose();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Material(
            color: const Color(0xFF1B2128),
            elevation: 8,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: switch (_type) {
                _FilterType.numeric => _numericBody(),
                _FilterType.date => _dateBody(),
                _FilterType.categorical => _categoricalBody(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _categoricalBody() {
    final visible = _visibleValues();
    final visibleSet = visible.toSet();
    final visibleCheckedCount =
        visible.where((v) => !_excluded.contains(v)).length;
    final allChecked =
        visible.isNotEmpty && visibleCheckedCount == visible.length;
    final noneChecked = visibleCheckedCount == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 8),
        _searchField(),
        const SizedBox(height: 6),
        _selectToggle(allChecked, noneChecked, visibleSet),
        const Divider(height: 1, color: Color(0xFF2A3038)),
        Expanded(child: _list(visible)),
        if (_truncated)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'List truncated. Refine with search.',
              style: TextStyle(
                  color: Color(0xFF6B7480),
                  fontSize: 11,
                  fontStyle: FontStyle.italic),
            ),
          ),
        const Divider(height: 1, color: Color(0xFF2A3038)),
        const SizedBox(height: 6),
        _actions(),
      ],
    );
  }

  Widget _numericBody() {
    final hasBounds = _columnMin != null && _columnMax != null;
    final loBound = _columnMin?.toDouble() ?? 0;
    final hiBound = _columnMax?.toDouble() ?? 1;
    final span = hiBound - loBound;

    // Parse the current field values; fall back to the column bounds so the
    // slider has a well-defined initial position when fields are empty.
    final liveLo =
        (num.tryParse(_minCtrl.text.trim())?.toDouble() ?? loBound)
            .clamp(loBound, hiBound);
    final liveHi =
        (num.tryParse(_maxCtrl.text.trim())?.toDouble() ?? hiBound)
            .clamp(loBound, hiBound);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _numField('Min', _minCtrl, focusNode: _minFocus)),
            const SizedBox(width: 8),
            Expanded(child: _numField('Max', _maxCtrl)),
          ],
        ),
        if (hasBounds && span > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: SizedBox(
              height: 32,
              child: CustomPaint(
                painter: _HistogramPainter(
                  bins: _numericBins(loBound, hiBound),
                  activeStart: ((liveLo - loBound) / span).clamp(0.0, 1.0),
                  activeEnd: ((liveHi - loBound) / span).clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
        if (hasBounds && span > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 0),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                rangeThumbShape:
                    const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                showValueIndicator: ShowValueIndicator.onDrag,
              ),
              child: RangeSlider(
                values: RangeValues(
                    liveLo < liveHi ? liveLo : liveHi, liveHi),
                min: loBound,
                max: hiBound,
                activeColor: const Color(0xFF1E88E5),
                inactiveColor: const Color(0xFF2A3038),
                labels: RangeLabels(
                    _formatNum(liveLo), _formatNum(liveHi)),
                onChanged: (values) {
                  // Suppress the listener round-trip while we set both
                  // fields, otherwise the second update would fight the
                  // first by re-parsing stale text.
                  _minCtrl.removeListener(_onRangeFieldsChange);
                  _maxCtrl.removeListener(_onRangeFieldsChange);
                  _minCtrl.text = _formatNum(values.start);
                  _maxCtrl.text = _formatNum(values.end);
                  _minCtrl.addListener(_onRangeFieldsChange);
                  _maxCtrl.addListener(_onRangeFieldsChange);
                  setState(() {});
                },
              ),
            ),
          ),
        if (hasBounds)
          Text(
            'Column range ${_formatNum(_columnMin!)} … ${_formatNum(_columnMax!)}',
            style: const TextStyle(color: Color(0xFF6B7480), fontSize: 11),
          ),
        const Spacer(),
        const Divider(height: 1, color: Color(0xFF2A3038)),
        const SizedBox(height: 6),
        _actions(),
      ],
    );
  }

  Widget _dateBody() {
    final hasBounds = _dateMin != null && _dateMax != null;
    final spanMs = hasBounds
        ? (_dateMax!.millisecondsSinceEpoch - _dateMin!.millisecondsSinceEpoch)
            .toDouble()
        : 0.0;
    final liveLoDate = DateTime.tryParse(_minCtrl.text.trim());
    final liveHiDate = DateTime.tryParse(_maxCtrl.text.trim());
    double activeStart = 0;
    double activeEnd = 1;
    if (hasBounds && spanMs > 0) {
      if (liveLoDate != null) {
        activeStart = ((liveLoDate.millisecondsSinceEpoch -
                    _dateMin!.millisecondsSinceEpoch) /
                spanMs)
            .clamp(0.0, 1.0);
      }
      if (liveHiDate != null) {
        activeEnd = ((liveHiDate.millisecondsSinceEpoch -
                    _dateMin!.millisecondsSinceEpoch) /
                spanMs)
            .clamp(0.0, 1.0);
      }
    }

    final hint = hasBounds
        ? 'range ${_formatDate(_dateMin!)} … ${_formatDate(_dateMax!)}'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
                child: _numField('From', _minCtrl,
                    focusNode: _minFocus,
                    hint: 'YYYY-MM-DD',
                    numeric: false)),
            const SizedBox(width: 8),
            Expanded(
                child: _numField('To', _maxCtrl,
                    hint: 'YYYY-MM-DD', numeric: false)),
          ],
        ),
        if (hasBounds && spanMs > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: SizedBox(
              height: 32,
              child: CustomPaint(
                painter: _HistogramPainter(
                  bins: _dateBins(_dateMin!, _dateMax!),
                  activeStart: activeStart,
                  activeEnd: activeEnd,
                ),
              ),
            ),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Column $hint',
              style: const TextStyle(
                  color: Color(0xFF6B7480), fontSize: 11),
            ),
          ),
        const Spacer(),
        const Divider(height: 1, color: Color(0xFF2A3038)),
        const SizedBox(height: 6),
        _actions(),
      ],
    );
  }

  /// Returns the count of non-null numeric values per bin. 30 bins is a
  /// good compromise for a 240px-wide popup: each bar gets ~8px, enough
  /// for a 1px gap and a 7px bar.
  List<int> _numericBins(double lo, double hi) {
    const binCount = 30;
    final bins = List<int>.filled(binCount, 0);
    final span = hi - lo;
    if (span <= 0) return bins;
    for (final v in _allValues) {
      if (v is! num) continue;
      var idx = ((v.toDouble() - lo) / span * binCount).floor();
      if (idx < 0) idx = 0;
      if (idx >= binCount) idx = binCount - 1;
      bins[idx]++;
    }
    return bins;
  }

  List<int> _dateBins(DateTime lo, DateTime hi) {
    const binCount = 30;
    final bins = List<int>.filled(binCount, 0);
    final loMs = lo.millisecondsSinceEpoch;
    final hiMs = hi.millisecondsSinceEpoch;
    final span = hiMs - loMs;
    if (span <= 0) return bins;
    for (final v in _allValues) {
      if (v is! DateTime) continue;
      var idx =
          ((v.millisecondsSinceEpoch - loMs) / span * binCount).floor();
      if (idx < 0) idx = 0;
      if (idx >= binCount) idx = binCount - 1;
      bins[idx]++;
    }
    return bins;
  }

  Widget _numField(String label, TextEditingController c,
      {FocusNode? focusNode, String? hint, bool numeric = true}) {
    return TextField(
      controller: c,
      focusNode: focusNode,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      style: const TextStyle(color: Color(0xFFE6ECF2), fontSize: 12),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        hintStyle:
            const TextStyle(color: Color(0xFF4A555F), fontSize: 11),
        labelStyle:
            const TextStyle(color: Color(0xFF6B7480), fontSize: 11),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        filled: true,
        fillColor: const Color(0xFF101418),
        border: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF2A3038)),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF2A3038)),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF1E88E5)),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
      onSubmitted: (_) => _apply(),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Icon(Icons.filter_alt_outlined,
            size: 14, color: Color(0xFF9AA4AD)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.column.header,
            style: const TextStyle(
                color: Color(0xFFD7DEE6),
                fontSize: 12,
                fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        InkWell(
          onTap: widget.onClose,
          child: const Padding(
            padding: EdgeInsets.all(2),
            child: Icon(Icons.close, size: 14, color: Color(0xFF9AA4AD)),
          ),
        ),
      ],
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _search,
      focusNode: _searchFocus,
      style: const TextStyle(color: Color(0xFFE6ECF2), fontSize: 12),
      decoration: const InputDecoration(
        isDense: true,
        hintText: 'Search…',
        hintStyle: TextStyle(color: Color(0xFF6B7480), fontSize: 12),
        prefixIcon:
            Icon(Icons.search, size: 14, color: Color(0xFF6B7480)),
        prefixIconConstraints: BoxConstraints(minWidth: 26, minHeight: 26),
        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        filled: true,
        fillColor: Color(0xFF101418),
        border: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF2A3038)),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF2A3038)),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF1E88E5)),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
      onSubmitted: (_) => _apply(),
    );
  }

  Widget _selectToggle(bool allChecked, bool noneChecked, Set<Object?> visibleSet) {
    // Operate on the currently-visible subset so "Select all" with a search
    // active toggles only the matched rows. That matches Excel's behavior
    // and lets the user uncheck the entire visible group with one click.
    return InkWell(
      onTap: () {
        setState(() {
          if (allChecked) {
            _excluded.addAll(visibleSet);
          } else {
            _excluded.removeAll(visibleSet);
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          children: [
            _Tristate(
              checked: allChecked,
              partial: !allChecked && !noneChecked,
            ),
            const SizedBox(width: 8),
            Text(
              allChecked ? 'Clear visible' : '(Select all visible)',
              style: const TextStyle(
                color: Color(0xFFB8C0CC),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(List<Object?> visible) {
    if (visible.isEmpty) {
      return const Center(
        child: Text('No matches',
            style: TextStyle(color: Color(0xFF6B7480), fontSize: 12)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemExtent: 24,
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final v = visible[i];
        final checked = _isChecked(v);
        return InkWell(
          onTap: () => _toggle(v),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              children: [
                _Tristate(checked: checked, partial: false),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _labelFor(v),
                    style: const TextStyle(
                      color: Color(0xFFE6ECF2),
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _actions() {
    return Row(
      children: [
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            foregroundColor: const Color(0xFF9AA4AD),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: _clear,
          child: const Text('Clear filter', style: TextStyle(fontSize: 12)),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            backgroundColor: const Color(0xFF1E88E5),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: _apply,
          child: const Text('Apply', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

/// Tiny custom-painted checkbox so the popup doesn't drag in Flutter's
/// Material `Checkbox` (which forces a 48dp tap target and burns vertical
/// rhythm at this density).
class _Tristate extends StatelessWidget {
  const _Tristate({required this.checked, required this.partial});
  final bool checked;
  final bool partial;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(14, 14),
      painter: _TristatePainter(checked: checked, partial: partial),
    );
  }
}

class _TristatePainter extends CustomPainter {
  _TristatePainter({required this.checked, required this.partial});
  final bool checked;
  final bool partial;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1);
    final border = Paint()
      ..color = const Color(0xFF4A555F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fill = Paint()..color = const Color(0xFF1E88E5);

    if (checked || partial) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(2)), fill);
    } else {
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(2)), border);
    }

    if (checked) {
      final tick = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      final p = Path()
        ..moveTo(size.width * 0.22, size.height * 0.55)
        ..lineTo(size.width * 0.45, size.height * 0.75)
        ..lineTo(size.width * 0.78, size.height * 0.30);
      canvas.drawPath(p, tick);
    } else if (partial) {
      final bar = Paint()
        ..color = Colors.white
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(size.width * 0.25, size.height * 0.5),
        Offset(size.width * 0.75, size.height * 0.5),
        bar,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TristatePainter old) =>
      old.checked != checked || old.partial != partial;
}

enum _FilterType { categorical, numeric, date }

/// Tiny histogram drawn above the range slider in the numeric/date filter
/// branch. Active bins (those inside the current selection) draw in the
/// accent color; the rest in a muted gridline tone. Heights are scaled
/// against the tallest bin's count so all bars fit the band.
class _HistogramPainter extends CustomPainter {
  _HistogramPainter({
    required this.bins,
    required this.activeStart,
    required this.activeEnd,
  });

  static const Color _active = Color(0xFF1E88E5);
  static const Color _inactive = Color(0xFF2A3038);

  final List<int> bins;
  final double activeStart;
  final double activeEnd;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty) return;
    var maxCount = 0;
    for (final c in bins) {
      if (c > maxCount) maxCount = c;
    }
    if (maxCount == 0) return;
    final barW = size.width / bins.length;
    final gap = (barW * 0.18).clamp(0.5, 3.0);
    final innerW = barW - gap;
    final activePaint = Paint()..color = _active;
    final inactivePaint = Paint()..color = _inactive;
    for (var i = 0; i < bins.length; i++) {
      final t = (i + 0.5) / bins.length;
      final isActive = t >= activeStart && t <= activeEnd;
      final h = (bins[i] / maxCount) * size.height;
      canvas.drawRect(
        Rect.fromLTWH(i * barW + gap / 2, size.height - h, innerW, h),
        isActive ? activePaint : inactivePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) =>
      old.activeStart != activeStart ||
      old.activeEnd != activeEnd ||
      old.bins != bins;
}
