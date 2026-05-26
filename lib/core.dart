/// Pineal core — primitives shared by every visualization family.
///
/// Import this entry point if you're writing your own renderer on top of
/// Pineal and don't need the cartesian or mesh modules. Tree-shaking
/// drops everything you don't reference at AOT release time, so importing
/// `core.dart` alone yields the smallest possible binary surface.
library;

export 'src/data/data_buffer.dart';
export 'src/data/spatial_index.dart';
export 'src/data/data_animator.dart';
export 'src/data/lttb.dart';
export 'src/data/r_tree.dart';

export 'src/painters/text_cache.dart';

export 'src/render/fragment_shader_loader.dart';
