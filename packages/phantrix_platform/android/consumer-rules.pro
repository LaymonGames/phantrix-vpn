# Consumer rules for the Phantrix platform bridge.
#
# The plugin and tunnel service are referenced from the manifest and the plugin
# registrar, which R8 cannot trace from an entry point.
-keep class dev.phantrix.phantrix_platform.** { *; }
-keep interface dev.phantrix.phantrix_platform.** { *; }
