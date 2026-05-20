/// Tabla "bonita" de personas — pensada para listados como `/admin/usuarios`
/// o estudiantes activos del rol CDE. Construida con widgets normales
/// (no usa el painter de PinealGrid) para permitir avatares circulares
/// de iniciales, badges, hover-row y action trailing por fila.
///
/// API mínima — caller pasa filas + descriptores de columna + opcional
/// header (título, subtítulo, chips de stats) y handlers.
library pineal.user_table;

import 'package:flutter/material.dart';

/// Una fila de la tabla. `cells` se accede por `columnKey`.
class UserTableRow {
  /// Id estable — usado como key del row.
  final String id;

  /// Nombre que ocupa la primera columna (apellido, nombres).
  final String name;

  /// Sub-identificador mostrado debajo del nombre en mono (ej. `est_94adb`).
  final String? subId;

  /// Url opcional. Si es null se renderizan iniciales coloreadas por hash
  /// del [name].
  final String? avatarUrl;

  /// Valores por `column.key`. Strings se renderizan tal cual; otros tipos
  /// se pasan a `toString()`.
  final Map<String, dynamic> cells;

  /// Pildoras de estado al lado del nombre o en la columna `_badges` si la
  /// configuras explícitamente.
  final List<UserTableBadge> badges;

  /// Si `true`, fila ligeramente atenuada (ej. usuario inactivo).
  final bool muted;

  const UserTableRow({
    required this.id,
    required this.name,
    this.subId,
    this.avatarUrl,
    this.cells = const {},
    this.badges = const [],
    this.muted = false,
  });
}

/// Descriptor de una columna lógica.
class UserTableColumn {
  final String key;
  final String label;
  final double? width;
  final TextAlign align;
  final bool numeric;

  /// Builder opcional. Si está, sustituye el render por defecto de
  /// `row.cells[key].toString()`.
  final Widget Function(BuildContext, UserTableRow row)? cellBuilder;

  const UserTableColumn({
    required this.key,
    required this.label,
    this.width,
    this.align = TextAlign.left,
    this.numeric = false,
    this.cellBuilder,
  });
}

/// Stat compacto del header — ej. "232 activos", "13 en riesgo".
class UserTableStat {
  final String label;
  final int count;
  final Color? color;
  const UserTableStat({required this.label, required this.count, this.color});
}

/// Píldora de estado adyacente a una fila.
class UserTableBadge {
  final String label;
  final Color color;
  final IconData? icon;
  const UserTableBadge({
    required this.label,
    required this.color,
    this.icon,
  });
}

/// Chip de filtro mostrado encima de la tabla — ej. "Todos 248 ·
/// Preescolar 39 · Primaria 72 · Bachillerato 117".
class UserTableChipFilter {
  final String key;
  final String label;
  final int? count;
  const UserTableChipFilter({
    required this.key,
    required this.label,
    this.count,
  });
}

class PinealUserTable extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<UserTableColumn> columns;
  final List<UserTableRow> rows;

  /// Stats grandes en línea superior derecha del header.
  final List<UserTableStat> headerStats;

  /// Chips de filtro debajo del search bar. Si está vacío, no se renderiza
  /// la fila.
  final List<UserTableChipFilter> chipFilters;
  final String? activeChipKey;
  final ValueChanged<String?>? onChipChanged;

  /// Acción principal del header (botón naranja "Nuevo X" del mockup).
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;

  /// Acción secundaria (botón blanco "Exportar" del mockup).
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  /// Callback al hacer click en "Abrir" (o en toda la fila).
  final void Function(UserTableRow row)? onOpen;

  final String searchHint;
  final int pageSize;

  /// Si quieres mostrar un toast verde al pie ("Mateo Pérez guardado.
  /// Listo para el siguiente."), pásalo aquí. Pasa null para ocultarlo.
  final String? footerToast;

  const PinealUserTable({
    super.key,
    required this.title,
    this.subtitle,
    required this.columns,
    required this.rows,
    this.headerStats = const [],
    this.chipFilters = const [],
    this.activeChipKey,
    this.onChipChanged,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.onOpen,
    this.searchHint = 'Buscar…',
    this.pageSize = 10,
    this.footerToast,
  });

  @override
  State<PinealUserTable> createState() => _PinealUserTableState();
}

class _PinealUserTableState extends State<PinealUserTable> {
  late final TextEditingController _searchCtrl = TextEditingController();
  String? _hoveredId;
  int _page = 0;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<UserTableRow> get _filteredRows {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.rows;
    return widget.rows.where((r) {
      if (r.name.toLowerCase().contains(q)) return true;
      if (r.subId?.toLowerCase().contains(q) ?? false) return true;
      return r.cells.values.any((v) =>
          v?.toString().toLowerCase().contains(q) ?? false);
    }).toList();
  }

  List<UserTableRow> get _pagedRows {
    final filtered = _filteredRows;
    final start = _page * widget.pageSize;
    if (start >= filtered.length) return const [];
    final end = (start + widget.pageSize).clamp(0, filtered.length);
    return filtered.sublist(start, end);
  }

  int get _totalPages {
    final n = _filteredRows.length;
    if (n == 0) return 1;
    return (n / widget.pageSize).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(cs),
          const SizedBox(height: 14),
          _buildSearchRow(cs),
          if (widget.chipFilters.isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildChipFilters(cs),
          ],
          const SizedBox(height: 14),
          _buildTableHeader(cs),
          const Divider(height: 1),
          ..._pagedRows.map((r) => _buildRow(cs, r)),
          if (_pagedRows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text(
                'Sin resultados',
                style: TextStyle(color: cs.outline),
              )),
            ),
          const Divider(height: 1),
          const SizedBox(height: 10),
          _buildFooter(cs),
          if (widget.footerToast != null) ...[
            const SizedBox(height: 14),
            _buildToast(cs, widget.footerToast!),
          ],
        ],
      ),
    );
  }

  // ── Header con título, subtítulo, stats y acciones ─────────────────

  Widget _buildHeader(ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(text: TextSpan(
              style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w900,
                color: cs.onSurface, letterSpacing: -0.6, height: 1.05,
              ),
              children: [
                TextSpan(text: '${widget.title} '),
                if (widget.subtitle != null)
                  TextSpan(
                    text: _highlightItalic(widget.title),
                    style: TextStyle(
                      fontStyle: FontStyle.italic, color: cs.primary,
                    ),
                  ),
              ],
            )),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 6),
              Text(widget.subtitle!,
                style: TextStyle(fontSize: 13, color: cs.outline)),
            ],
          ],
        )),
        const SizedBox(width: 16),
        if (widget.secondaryActionLabel != null)
          OutlinedButton(
            onPressed: widget.onSecondaryAction,
            child: Text(widget.secondaryActionLabel!),
          ),
        if (widget.secondaryActionLabel != null &&
            widget.primaryActionLabel != null)
          const SizedBox(width: 8),
        if (widget.primaryActionLabel != null)
          FilledButton(
            onPressed: widget.onPrimaryAction,
            child: Text(widget.primaryActionLabel!),
          ),
      ],
    );
  }

  /// Helper de "Estudiantes activos" → solo la última palabra en cursiva
  /// (heurística del mockup). Como `RichText` usa segundo TextSpan vacío
  /// si no hay subtitle, sobreescribimos aquí.
  String _highlightItalic(String s) {
    final parts = s.split(' ');
    if (parts.length < 2) return '';
    return parts.last;
  }

  // ── Search bar + stats inline ──────────────────────────────────────

  Widget _buildSearchRow(ColorScheme cs) {
    return Row(children: [
      Expanded(child: TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          hintText: widget.searchHint,
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.outlineVariant),
          ),
        ),
        onChanged: (_) => setState(() => _page = 0),
      )),
      if (widget.headerStats.isNotEmpty) ...[
        const SizedBox(width: 16),
        Wrap(spacing: 16, children: [
          for (final s in widget.headerStats)
            _statPill(cs, s),
        ]),
      ],
    ]);
  }

  Widget _statPill(ColorScheme cs, UserTableStat s) {
    final color = s.color ?? cs.primary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text('${s.count} ${s.label}',
        style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700, color: cs.onSurface)),
    ]);
  }

  // ── Chips de filtro ────────────────────────────────────────────────

  Widget _buildChipFilters(ColorScheme cs) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final c in widget.chipFilters)
        _chip(cs, c, c.key == widget.activeChipKey),
    ]);
  }

  Widget _chip(ColorScheme cs, UserTableChipFilter c, bool active) {
    final bg = active ? cs.primary : cs.surfaceContainerHighest;
    final fg = active ? cs.onPrimary : cs.onSurface;
    return InkWell(
      onTap: () {
        if (widget.onChipChanged != null) {
          widget.onChipChanged!(c.key);
          setState(() => _page = 0);
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? cs.primary : cs.outlineVariant),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(c.label, style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w700, color: fg)),
          if (c.count != null) ...[
            const SizedBox(width: 6),
            Text('${c.count}', style: TextStyle(
              fontSize: 11.5,
              color: active ? cs.onPrimary.withValues(alpha: 0.7)
                            : cs.outline)),
          ],
        ]),
      ),
    );
  }

  // ── Tabla ──────────────────────────────────────────────────────────

  Widget _buildTableHeader(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        const SizedBox(width: 56),
        Expanded(flex: 3, child: _headerCell(cs, widget.columns.isNotEmpty
            ? widget.columns.first.label : 'Nombre')),
        for (final col in widget.columns.skip(1))
          SizedBox(
            width: col.width ?? 130,
            child: _headerCell(cs, col.label, align: col.align),
          ),
        const SizedBox(width: 72),  // espacio para "Abrir"
      ]),
    );
  }

  Widget _headerCell(ColorScheme cs, String label,
      {TextAlign align = TextAlign.left}) {
    return Text(label,
      textAlign: align,
      style: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w800,
        letterSpacing: 0.5, color: cs.outline,
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, UserTableRow row) {
    final hovered = _hoveredId == row.id;
    final firstCol = widget.columns.isNotEmpty ? widget.columns.first : null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredId = row.id),
      onExit: (_) => setState(() => _hoveredId = null),
      child: InkWell(
        onTap: widget.onOpen == null ? null : () => widget.onOpen!(row),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          color: hovered
              ? cs.primary.withValues(alpha: 0.04)
              : Colors.transparent,
          child: Row(children: [
            SizedBox(width: 48, child: _Avatar(name: row.name)),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: _nameCell(cs, row, firstCol)),
            for (final col in widget.columns.skip(1))
              SizedBox(
                width: col.width ?? 130,
                child: _bodyCell(cs, row, col),
              ),
            SizedBox(
              width: 72,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: hovered ? 1 : 0.5,
                  child: TextButton(
                    onPressed: widget.onOpen == null
                        ? null : () => widget.onOpen!(row),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('Abrir',
                      style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700,
                        color: cs.primary)),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _nameCell(ColorScheme cs, UserTableRow r, UserTableColumn? col) {
    final color = r.muted ? cs.outline : cs.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(r.name,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5, fontWeight: FontWeight.w800, color: color)),
        if (r.subId != null)
          Text(r.subId!,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11, fontFamily: 'monospace',
              color: cs.outline)),
      ],
    );
  }

  Widget _bodyCell(ColorScheme cs, UserTableRow r, UserTableColumn col) {
    if (col.cellBuilder != null) return col.cellBuilder!(context, r);
    // Columna especial: '_badges' renderiza los UserTableBadge del row.
    if (col.key == '_badges') {
      return Wrap(spacing: 4, runSpacing: 4, children: [
        for (final b in r.badges) _badgeChip(cs, b),
      ]);
    }
    final value = r.cells[col.key];
    if (value == null) {
      return Text('—',
        textAlign: col.align,
        style: TextStyle(fontSize: 12.5, color: cs.outline));
    }
    return Text(value.toString(),
      textAlign: col.align,
      maxLines: 1, overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: col.numeric ? FontWeight.w700 : FontWeight.w500,
        color: r.muted ? cs.outline : cs.onSurface));
  }

  Widget _badgeChip(ColorScheme cs, UserTableBadge b) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: b.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (b.icon != null) ...[
          Icon(b.icon, size: 10, color: b.color),
          const SizedBox(width: 3),
        ],
        Text(b.label,
          style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w800, color: b.color)),
      ]),
    );
  }

  // ── Footer con paginación humana ───────────────────────────────────

  Widget _buildFooter(ColorScheme cs) {
    final n = _filteredRows.length;
    final shown = _pagedRows.length;
    return Row(children: [
      Text('Página ${_page + 1} de $_totalPages · '
           '$shown mostrados${n != widget.rows.length ? " de $n" : ""}',
        style: TextStyle(fontSize: 12, color: cs.outline)),
      const Spacer(),
      OutlinedButton(
        onPressed: _page == 0
            ? null : () => setState(() => _page--),
        child: const Text('Anterior'),
      ),
      const SizedBox(width: 8),
      OutlinedButton(
        onPressed: _page + 1 >= _totalPages
            ? null : () => setState(() => _page++),
        child: const Text('Siguiente'),
      ),
    ]);
  }

  Widget _buildToast(ColorScheme cs, String msg) {
    return Center(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: cs.inverseSurface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(msg,
        style: TextStyle(
          fontSize: 12.5, color: cs.onInverseSurface,
          fontWeight: FontWeight.w600)),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────
// Avatar circular con iniciales coloreadas por hash del nombre.
// ─────────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  static const _palette = <Color>[
    Color(0xFFEF6C57), // coral
    Color(0xFF7A78D1), // periwinkle
    Color(0xFF42B883), // mint
    Color(0xFFEAA13C), // amber
    Color(0xFF5BA9D8), // sky
    Color(0xFFD05BB1), // pink
    Color(0xFF8C7AC1), // lavender
    Color(0xFFE07A5F), // terracotta
  ];

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  Color get _color {
    final h = name.codeUnits.fold<int>(0, (a, b) => a + b);
    return _palette[h % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32, height: 32,
      decoration: BoxDecoration(
        color: _color, shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(_initials,
        style: const TextStyle(
          color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w900)),
    );
  }
}
