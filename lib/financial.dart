/// Pineal financial — OHLC candlestick series with volatility-preserving
/// downsampling. Designed to drop into [PinealChart] alongside line/area
/// series, so multi-axis trading dashboards stay declarative.
library pineal.financial;

export 'cartesian.dart';

export 'src/financial/ohlc_buffer.dart';
export 'src/financial/ohlc_downsample.dart';
export 'src/financial/candlestick_series.dart';
