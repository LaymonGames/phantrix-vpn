# Release builds are minified, so the classes the engine and the WireGuard
# bridge reach reflectively need explicit keep rules. R8 cannot see those
# references from the Dart side of the build.
#
# Everything here exists because something is looked up by name at runtime.
# Nothing here exists to silence a warning.

# Flutter's embedding and the plugin registrar. The engine calls into these by
# name from native code, which R8 never sees as a reference.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-dontwarn io.flutter.embedding.**

# The app's own plugin and the tunnel service it starts. The service is
# referenced from the manifest and bound through an Intent by name.
-keep class dev.phantrix.phantrix.PhantrixPlugin { *; }
-keep class dev.phantrix.phantrix.PhantrixTunnelService { *; }
-keep class dev.phantrix.phantrix.PhantrixTunnelService$* { *; }

# wireguard-android keeps its Go bridge behind JNI. The native library calls
# these by their exact names, so a renamed class is a crash at connect time
# rather than a compile error.
-keep class com.wireguard.android.** { *; }
-keep interface com.wireguard.android.** { *; }
-dontwarn com.wireguard.android.**

# Kotlin coroutines, which the tunnel service uses for its handshake watcher.
-dontwarn kotlinx.coroutines.**
