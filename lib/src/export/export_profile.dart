/// Output medium description used by [SvgExporter] (and any future
/// PDF/PNG exporters) to decide how aggressively to downsample series.
class ExportProfile {
  const ExportProfile({
    this.dpi = 96,
    this.widthInches = 8.0,
    this.heightInches = 4.5,
    this.verticesPerPixel = 3,
  });

  /// Targets a 300 DPI print on a half-letter landscape page.
  static const ExportProfile print = ExportProfile(
    dpi: 300,
    widthInches: 8.5,
    heightInches: 5.5,
  );

  /// Targets a 96 DPI screen capture sized for inline documentation.
  static const ExportProfile screen = ExportProfile(
    dpi: 96,
    widthInches: 8.0,
    heightInches: 4.5,
  );

  /// Targets a 144 DPI retina-scale image suitable for slide decks.
  static const ExportProfile retina = ExportProfile(
    dpi: 144,
    widthInches: 10.0,
    heightInches: 5.5,
  );

  final double dpi;
  final double widthInches;
  final double heightInches;

  /// Vertices kept per output pixel after contextual decimation. `3` is the
  /// same default the screen renderer uses — preserves visual silhouette
  /// without bloating the file.
  final int verticesPerPixel;

  /// Pixel-equivalent width of the output medium.
  double get pixelWidth => widthInches * dpi;

  /// Pixel-equivalent height of the output medium.
  double get pixelHeight => heightInches * dpi;

  /// Maximum vertex count any single series may emit after decimation.
  int get targetVertices => (pixelWidth * verticesPerPixel).round();
}
