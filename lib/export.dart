/// Pineal export — vectorial export of cartesian charts as SVG.
///
/// Independent module: importing this entry point gives you the exporter
/// and the [ExportProfile] DPI helpers. Apps that don't render reports
/// can leave it out of their tree-shaken bundle.
library;

export 'cartesian.dart';

export 'src/export/export_profile.dart';
export 'src/export/svg_exporter.dart';
