import 'dart:ui' as ui;

/// Loads `.frag` GLSL programs and hands back ready-to-use [ui.FragmentShader]
/// instances. Programs are cached by asset key.
///
/// Usage:
///
/// ```dart
/// final shader = await FragmentShaderLoader.load('shaders/glow.frag');
/// shader.setFloat(0, 1.0); // configure uniforms
/// AreaSeries(..., shader: shader);
/// ```
///
/// Bundle the `.frag` file in your `pubspec.yaml`:
///
/// ```yaml
/// flutter:
///   shaders:
///     - shaders/glow.frag
/// ```
class FragmentShaderLoader {
  FragmentShaderLoader._();

  static final Map<String, ui.FragmentProgram> _programs = {};

  /// Compiles (or returns cached) [ui.FragmentProgram] for [asset].
  static Future<ui.FragmentProgram> program(String asset) async {
    final cached = _programs[asset];
    if (cached != null) return cached;
    final program = await ui.FragmentProgram.fromAsset(asset);
    _programs[asset] = program;
    return program;
  }

  /// Convenience: load the program and return a fresh [ui.FragmentShader].
  /// Callers configure uniforms and pass the result to a [Paint.shader].
  static Future<ui.FragmentShader> load(String asset) async {
    final p = await program(asset);
    return p.fragmentShader();
  }

  /// Drops every cached program. Mostly useful in hot-restart-heavy
  /// development loops; production code rarely needs this.
  static void clear() => _programs.clear();
}
