# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(phantrix LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "phantrix")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# === Licences ===
#
# A shipped Windows build carries the licence of the program, the licence of
# the engine it launches and the notice for the driver that engine needs, all
# in `licenses/` beside the executable.
#
# Before this, a release build carried exactly one licence file: OpenVPN's own,
# copied to the root of the bundle by the plugin's bundle list, where nothing
# identified it as OpenVPN's rather than the application's. The application's
# own GPL grant, the copyright notice, the third-party inventory and the wintun
# notice were in the repository and in the installer's absence, on no machine
# that ran the app.
#
# The OpenVPN and wintun texts come from `tools/attribution/`, which keeps the
# checked-in copy of the fetched bundle's notices. That is what makes this rule
# work without network access and on a machine where the engine bundle has not
# been fetched at all.
set(PHANTRIX_LICENCE_DIR "${CMAKE_INSTALL_PREFIX}/licenses")

# The licence that came with the fetched engine wins over the checked-in copy,
# so the text installed is the one for the bytes that ship. This mirrors the
# generator, which prefers the bundle's own copy for the same reason. The
# checked-in copy stays as the fallback, because a configure without the bundle
# still has to install a notice.
set(PHANTRIX_OPENVPN_LICENCE
  "${CMAKE_CURRENT_SOURCE_DIR}/../tools/attribution/openvpn-copying.txt")
set(PHANTRIX_BUNDLE_LICENCE
  "${CMAKE_CURRENT_SOURCE_DIR}/../packages/phantrix_platform/windows/bundle/openvpn/LICENSE.txt")
if(EXISTS "${PHANTRIX_BUNDLE_LICENCE}")
  set(PHANTRIX_OPENVPN_LICENCE "${PHANTRIX_BUNDLE_LICENCE}")
endif()

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../LICENSE"
  DESTINATION "${PHANTRIX_LICENCE_DIR}"
  RENAME "phantrix-LICENSE.txt"
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../COPYRIGHT"
  DESTINATION "${PHANTRIX_LICENCE_DIR}"
  RENAME "phantrix-COPYRIGHT.txt"
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../THIRD_PARTY_LICENSES.md"
  DESTINATION "${PHANTRIX_LICENCE_DIR}"
  RENAME "phantrix-THIRD_PARTY_LICENSES.md"
  COMPONENT Runtime)
install(FILES "${PHANTRIX_OPENVPN_LICENCE}"
  DESTINATION "${PHANTRIX_LICENCE_DIR}"
  RENAME "openvpn-LICENSE.txt"
  COMPONENT Runtime)
install(
  FILES "${CMAKE_CURRENT_SOURCE_DIR}/../tools/attribution/wintun-prebuilt-license.txt"
  DESTINATION "${PHANTRIX_LICENCE_DIR}"
  RENAME "wintun-LICENSE.txt"
  COMPONENT Runtime)
