#ifndef FLUTTER_PLUGIN_PHANTRIX_PLUGIN_H_
#define FLUTTER_PLUGIN_PHANTRIX_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

// Declares the plugin's GObject type: the instance typedef, the class
// typedef, the cast macros, and `phantrix_platform_linux_get_type`.
//
// This is what makes `G_DEFINE_TYPE` in the implementation file valid: that
// macro refers to `PhantrixPlatformLinux##Class`, and without a declaration
// here the class struct would be undeclared and the build would fail. Using
// the GLib macro rather than hand-writing the typedefs is the difference
// between the cast macros being correct and being subtly wrong.
G_DECLARE_FINAL_TYPE(PhantrixPlatformLinux,
                     phantrix_platform_linux,
                     PHANTRIX,
                     PLATFORM_LINUX,
                     GObject)

// A single instance for the whole application. The tunnel name and the
// running state live on it, so a second instance would be able to create a
// second interface, which Android permits at most once.
FLUTTER_PLUGIN_EXPORT void phantrix_platform_linux_new(FlPluginRegistrar* registrar);

// The entry point Flutter's generated plugin registrant calls. The name must
// match `dartPluginClass` in the plugin's pubspec, converted to snake case.
FLUTTER_PLUGIN_EXPORT void phantrix_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_PHANTRIX_PLUGIN_H_
