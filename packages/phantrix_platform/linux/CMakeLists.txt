# The Linux build for the Phantrix platform bridge.
#
# The tunnel itself is the Linux kernel's own WireGuard implementation, driven
# through the official `wireguard-tools` commands. There is therefore no
# third-party library to link here: the dependency is a runtime tool that must
# be installed on the system, and its absence is reported to the user as an
# unsupported platform rather than worked around.
cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "phantrix_platform")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "phantrix_platform_plugin")

add_library(${PLUGIN_NAME} SHARED
  "phantrix_plugin.cc"
)
apply_standard_settings(${PLUGIN_NAME})

# Every symbol is hidden by default, so the one the registrant calls must be
# marked visible explicitly. Without these two lines the plugin builds, the
# registrant links, and the app fails at runtime with
# `dlsym(... undefined symbol)` — a linker-looking failure that is actually a
# visibility failure, and one that only appears on a device.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# INTERFACE, not PUBLIC: the include path is for consumers of this target
# (the generated plugin registrant in the host application), not for the
# target's own sources, which reference the header relative to the project
# root.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Intentionally empty: Phantrix bundles no Linux binaries. The tunnel is the
# separately installed `wireguard-tools` package plus the kernel module.
set(phantrix_platform_bundled_libraries "" PARENT_SCOPE)
