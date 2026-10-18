# Release builds are minified, so the classes the engine reaches reflectively
# need explicit keep rules. R8 cannot see those references from the Dart side
# of the build.
#
# Everything here exists because something is looked up by name at runtime.
# Nothing here exists to silence a warning.

# Flutter's embedding and the plugin registrar. The engine calls into these by
# name from native code, which R8 never sees as a reference.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-dontwarn io.flutter.embedding.**

# The platform bridge keeps its own classes: see its `consumer-rules.pro`,
# which travels with the library and is merged into this file at build time.
