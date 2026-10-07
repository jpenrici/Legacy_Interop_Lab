# legacy/extender/CMakeLists.txt
#
# Produces, all inside the portable part of the tree: lib/lib_cpp_api.so C ABI
# (lgx_*) for bindings; self-contained bin/cpp_extender_test tests of the C++
# core and of the C ABI The C bridge (lib/lib_c_api.so) is built by its own
# project and only imported.

cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(legacy_extender LANGUAGES CXX)

# Requires GCC 14 or newer (C++23 library support).
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_VERSION
                                               VERSION_LESS 14)
  message(
    FATAL_ERROR
      "GCC >= 14 required, found ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}"
  )
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Everything lands in legacy/bin and legacy/lib (the portable part).
get_filename_component(LEGACY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

set(WRAPPER_WARN -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wconversion)
set(WRAPPER_HARDEN -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
                   -fstack-protector-strong)
set(EXT_STATIC_RUNTIME -static-libstdc++ -static-libgcc)

# --- the C bridge, imported -------------------------------------------------
if(NOT EXISTS "${LEGACY_ROOT}/lib/lib_c_api.so")
  message(
    FATAL_ERROR "lib/lib_c_api.so not found - run: perl bridge/builder.pl")
endif()
add_library(c_api SHARED IMPORTED)
set_target_properties(
  c_api
  PROPERTIES IMPORTED_LOCATION "${LEGACY_ROOT}/lib/lib_c_api.so"
             IMPORTED_SONAME lib_c_api.so
             INTERFACE_INCLUDE_DIRECTORIES "${LEGACY_ROOT}/bridge/include")

# --- C++23 core (static): LedgerClient + Analytics --------------------------
add_library(extender_core STATIC src/legacy_extender.cpp src/analytics.cpp)
set_target_properties(
  extender_core
  PROPERTIES POSITION_INDEPENDENT_CODE ON
             CXX_VISIBILITY_PRESET hidden
             VISIBILITY_INLINES_HIDDEN ON)
target_include_directories(extender_core PUBLIC include)
target_link_libraries(extender_core PUBLIC c_api)
target_compile_options(extender_core PRIVATE ${EXT_WARN} ${EXT_HARDEN})

# --- lib/lib_cpp_api.so: the C ABI ----------------------------------
# Only lgx_* is exported: the core and the static libstdc++ are hidden, so the
# library cannot interpose on (or be interposed by) another C++ runtime that
# lives in the same process, e.g. in a Python interpreter.
add_library(legacy_extender SHARED src/ffi.cpp)
set_target_properties(
  legacy_extender
  PROPERTIES OUTPUT_NAME _cpp_api # -> lib_cpp_api.so
             CXX_VISIBILITY_PRESET hidden
             VISIBILITY_INLINES_HIDDEN ON
             LIBRARY_OUTPUT_DIRECTORY "${LEGACY_ROOT}/lib"
             # lib_c_api.so is found next to this library, wherever the tree is
             # moved to (the RUNPATH of an executable does not reach it).
             BUILD_WITH_INSTALL_RPATH ON
             INSTALL_RPATH "\$ORIGIN")
target_compile_options(legacy_extender PRIVATE ${EXT_WARN} ${EXT_HARDEN})
target_link_libraries(legacy_extender PRIVATE extender_core)
target_link_options(legacy_extender PRIVATE ${EXT_STATIC_RUNTIME}
                    -Wl,--exclude-libs,ALL -Wl,-z,defs)

# --- bin/cpp_extender_test -----------------------------------------------
add_executable(cpp_extender_test tests/main.cpp)
set_target_properties(
  cpp_extender_test
  PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${LEGACY_ROOT}/bin"
             BUILD_WITH_INSTALL_RPATH ON
             INSTALL_RPATH "\$ORIGIN/../lib")
target_compile_options(cpp_extender_test PRIVATE ${EXT_WARN} ${EXT_HARDEN})
target_link_libraries(cpp_extender_test PRIVATE extender_core legacy_extender)
target_link_options(cpp_extender_test PRIVATE ${EXT_STATIC_RUNTIME})

enable_testing()
add_test(
  NAME cpp_extender_test
  COMMAND cpp_extender_test
  WORKING_DIRECTORY "${LEGACY_ROOT}/bin")
