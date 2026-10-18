# Consumer rules for the Phantrix platform bridge.
#
# The plugin class is referenced from the plugin registrar, which R8 cannot
# trace from an entry point.
-keep class dev.phantrix.phantrix_platform.** { *; }
-keep interface dev.phantrix.phantrix_platform.** { *; }
