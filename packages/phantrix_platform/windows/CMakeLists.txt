# The Windows build for the Phantrix platform bridge.
#
# Three things are configured here:
#
#   1. the plugin library, which the Flutter engine loads into the unelevated
#      app and which owns the method and event channels;
#   2. a small helper executable that runs elevated, spawns the engine, and is
#      the only part of this plugin that ever holds an administrator token;
#   3. the third-party engine binaries that both of them find at run time.
#
# The only dependency beyond the Flutter C++ client wrapper is the Windows API,
# which arrives with the Windows SDK the Flutter Windows toolchain already
# requires. Nothing here builds a tunnel engine: OpenVPN is the official
# community binaries fetched by `tools/fetch_openvpn_bundle.ps1` with a pinned
# hash rather than written here, because a VPN data path nobody else has audited
# is the one thing a VPN client must not ship.
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "phantrix_platform")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "phantrix_platform_plugin")

add_library(${PLUGIN_NAME} SHARED
  "phantrix_windows_plugin.cpp"
  "phantrix_ovpn_support.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

# PUBLIC so the include directory reaches both this target and the generated
# plugin registrant in the host application, which includes the same header.
target_include_directories(${PLUGIN_NAME} PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# ---------------------------------------------------------------------------
# The elevated helper
# ---------------------------------------------------------------------------

# A separate executable rather than a branch inside the plugin, because it
# carries a `requireAdministrator` manifest and the app must never run elevated.
# It links against no Flutter at all: its only dependency is the Windows API,
# which is what makes it small enough to read in one sitting.
add_executable(phantrix_ovpn_helper WIN32
  "phantrix_ovpn_helper.cpp"
  "phantrix_ovpn_engine.cpp"
  "phantrix_ovpn_support.cpp"
)

apply_standard_settings(phantrix_ovpn_helper)

# WIN32 rather than CONSOLE: this program has nothing to show a user and must not
# flash a console window when the plugin starts it. The Windows subsystem entry
# point is `wWinMain`; this program reads its arguments from `GetCommandLineW`
# rather than from `argc`/`argv`, so nothing is lost by not having the CRT
# console entry point.
set_target_properties(phantrix_ovpn_helper PROPERTIES WIN32_EXECUTABLE TRUE)

# Its own directory, so it can include the shared support header without the
# plugin's public `include/` tree being on its path.
target_include_directories(phantrix_ovpn_helper PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

# The manifest is embedded into the executable so Windows shows the consent
# dialog when the plugin asks for it with ShellExecuteExW("runas").
#
# The linker's own `/MANIFESTINPUT` is deliberately not used. It merges the
# supplied manifest with the one the linker generates, and the two disagree about
# the requested execution level, which `mt.exe` reports as
# `c1010001: Values of attribute "level" not equal in different manifest
# snippets`. The execution level is passed to the linker directly instead, and
# the manifest file is read here to check that it says the same thing, so the
# file the privilege boundary is documented in is the file that is checked, not
# one that can drift from the build.
set(HELPER_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/phantrix_ovpn_helper.exe.manifest")
if(NOT EXISTS "${HELPER_MANIFEST}")
  message(FATAL_ERROR
    "phantrix_ovpn_helper.exe.manifest is missing. The helper must ask for "
    "administrator rights explicitly, and that request lives in that file.")
endif()
file(READ "${HELPER_MANIFEST}" HELPER_MANIFEST_TEXT)
string(FIND "${HELPER_MANIFEST_TEXT}" "level=\"requireAdministrator\"" ELEVATION_FOUND)
if(ELEVATION_FOUND LESS 0)
  message(FATAL_ERROR
    "phantrix_ovpn_helper.exe.manifest does not ask for administrator rights. "
    "The helper starts openvpn.exe, which creates the TUN adapter and installs "
    "routes; without this the tunnel cannot be created and the failure would "
    "appear only as an opaque refusal.")
endif()
target_link_options(phantrix_ovpn_helper PRIVATE
  "/MANIFESTUAC:level=requireAdministrator")

# ---------------------------------------------------------------------------
# The bundled engine
# ---------------------------------------------------------------------------

set(OPENVPN_BUNDLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/bundle/openvpn")

# Runtime dependencies and the accompanying OpenVPN license notice.
#
# The list is the engine's *import closure* minus the Windows SDK: `dumpbin
# /dependents openvpn.exe` names `libssl-3`, `libcrypto-3` and
# `libpkcs11-helper-1`, and those in turn name only each other and
# `vcruntime140`, so this is the whole set. It was found the hard way — the
# engine exits with 0xC0000135 and writes no log at all when a library in it is
# missing, which looks exactly like "the server does not answer".
#
# `vcruntime140.dll` is included even though a machine with the usual Visual C++
# redistributable has it, because a machine without it is a machine the user
# cannot diagnose. `wintun.dll` is the driver the engine needs for
# `--windows-driver wintun`, and it is looked for in the engine's own directory.
#
# The TAP helpers, the GUI, the easy-rsa scripts and the documentation that ship
# in the same installer are deliberately absent: this backend neither shows a UI
# nor runs a script, so shipping them would be tens of megabytes of executable
# that is never executed.
set(OPENVPN_BUNDLE_FILES
  "${OPENVPN_BUNDLE_DIR}/openvpn.exe"
  "${OPENVPN_BUNDLE_DIR}/libcrypto-3-x64.dll"
  "${OPENVPN_BUNDLE_DIR}/libssl-3-x64.dll"
  "${OPENVPN_BUNDLE_DIR}/libpkcs11-helper-1.dll"
  "${OPENVPN_BUNDLE_DIR}/vcruntime140.dll"
  "${OPENVPN_BUNDLE_DIR}/wintun.dll"
)

# The engine's `LICENSE.txt` is deliberately not in the list. These files are
# installed flat beside the executable, which put a file called `LICENSE.txt`
# next to `phantrix.exe` with nothing saying whose licence it was. It is
# installed as `licenses/openvpn-LICENSE.txt` by the application's own
# `windows/CMakeLists.txt` instead, which is the only place that can also
# install the application's licence and the notices for the other components.

# A build without the bundle still succeeds. The plugin reports the engine as
# missing and the Dart layer refuses an OpenVPN server with an explanation, so a
# missing bundle is a documented configuration state rather than a build
# failure. Only the files that are actually present are listed for installation,
# because `install(FILES)` on a path that does not exist is a configure error.
set(phantrix_platform_bundled_libraries "")
foreach(bundle_file IN LISTS OPENVPN_BUNDLE_FILES)
  if(EXISTS "${bundle_file}")
    list(APPEND phantrix_platform_bundled_libraries "${bundle_file}")
  endif()
endforeach()

# ---------------------------------------------------------------------------
# What the application bundle carries
# ---------------------------------------------------------------------------

# The helper is a build product, so its path is a generator expression rather
# than a literal. The application's generated-plugin rule already installs
# everything in this variable into the bundle beside the executable, which is
# where the plugin resolves the helper from.
list(APPEND phantrix_platform_bundled_libraries
  $<TARGET_FILE:phantrix_ovpn_helper>)

set(phantrix_platform_bundled_libraries "${phantrix_platform_bundled_libraries}"
  PARENT_SCOPE)
