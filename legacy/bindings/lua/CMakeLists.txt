# legacy/bindings/lua/CMakeLists.txt

cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(lua_bindings LANGUAGES C CXX)

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

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Requires Lua
find_package(Lua REQUIRED)

# Everything lands in legacy/bin and legacy/lib (the portable part).
get_filename_component(LEGACY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Defines centralized output folders for testing/distribution.
set(LUA_DIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/dist")

set(WRAPPER_WARN -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wconversion)
set(WRAPPER_HARDEN -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
                   -fstack-protector-strong)
set(EXT_STATIC_RUNTIME -static-libstdc++ -static-libgcc)

# --- the C++ extender, imported --------------------------------------------
if(NOT EXISTS "${LEGACY_ROOT}/lib/lib_cpp_api.so")
  message(
    FATAL_ERROR "lib/lib_cpp_api.so not found - run: perl extender/builder.pl")
endif()

add_library(cpp_api SHARED IMPORTED)
set_target_properties(
  cpp_api
  PROPERTIES IMPORTED_LOCATION "${LEGACY_ROOT}/lib/lib_cpp_api.so"
             IMPORTED_SONAME lib_cpp_api.so
             INTERFACE_INCLUDE_DIRECTORIES "${LEGACY_ROOT}/extender/include")

# --- the Lua Module (C Binding) -----------------------------------------------
if(Lua_FOUND)
  add_library(lua_extender_core MODULE lua_extender.c)

  target_compile_options(lua_extender_core PRIVATE ${WRAPPER_WARN}
                                                   ${WRAPPER_HARDEN})

  target_include_directories(
    lua_extender_core PRIVATE ${LUA_INCLUDE_DIR}
                              "${LEGACY_ROOT}/extender/include")

  target_link_libraries(lua_extender_core PRIVATE cpp_api ${LUA_LIBRARIES})

  # Place the compiled library directly into the dist/ folder.
  set_target_properties(
    lua_extender_core
    PROPERTIES PREFIX "" # Remove the prefix 'lib' from C for the Lua directly
                         # (ex: lua_extender_core.so)
               LIBRARY_OUTPUT_DIRECTORY "${LUA_DIST_DIR}"
               BUILD_WITH_INSTALL_RPATH ON
               INSTALL_RPATH "\$ORIGIN/../../lib")

  target_link_options(lua_extender_core PRIVATE ${EXT_STATIC_RUNTIME})

  # --- Copy (binding.lua and tests/*) to the dist/ folder. --------------------
  add_custom_target(
    lua_prepare_dist ALL
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/binding.lua"
            "${LUA_DIST_DIR}/binding.lua"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/tests" "${LUA_DIST_DIR}"
    DEPENDS lua_extender_core "${CMAKE_CURRENT_SOURCE_DIR}/binding.lua")

else()
  message(
    FATAL_ERROR
      "Lua not found. Please ensure the Lua library is installed on your system."
  )
endif()
