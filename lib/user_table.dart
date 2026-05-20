/// Pineal user-table — tabla "bonita" de personas con avatar de
/// iniciales, badges, paginación humana, hover row y action por fila.
///
/// A diferencia de `PinealGrid` (Canvas-puro, 1M filas), esta tabla
/// usa widgets normales — pensada para tamaños de N≤1k personas donde
/// avatares y badges valen el costo extra.
library;

export 'src/user_table/user_table.dart';
