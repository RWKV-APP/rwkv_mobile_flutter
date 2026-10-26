# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "rwkv_mobile_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
# add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(native_library "${CMAKE_CURRENT_SOURCE_DIR}/rwkv_mobile-arm64.dll")
  file(GLOB openmp_libraries "${CMAKE_CURRENT_SOURCE_DIR}/arm64/libomp*.dll")
else()
  set(RWKV_MOBILE_LIBRARY_DIR "${CMAKE_CURRENT_SOURCE_DIR}" CACHE PATH "Native runtime directory")
  set(native_library "${RWKV_MOBILE_LIBRARY_DIR}/rwkv_mobile.dll")
  set(openmp_libraries "${RWKV_MOBILE_LIBRARY_DIR}/libomp.dll")
endif()
set(rwkv_mobile_flutter_bundled_libraries ${native_library} ${openmp_libraries} PARENT_SCOPE)
