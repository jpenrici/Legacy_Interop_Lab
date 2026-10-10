# legacy/bindings/lua/CMakeLists.txt
#
# Produces legacy/bin/dist/lua, a folder that runs as it is:
# lua_extender_core.so, the native Lua 5.4 module (C) over lib_cpp_api.so;
# binding.lua, the high-level API; and main.lua in the tests/* the smoke test.
#
# Use the C++ extender (lib/lib_cpp_api.so) is built by its own project and only
# imported here.

cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(lua_bindings LANGUAGES C)

# Requires GCC 14 or newer, like the other native components.
if(NOT CMAKE_C_COMPILER_ID STREQUAL "GNU" OR CMAKE_C_COMPILER_VERSION
                                             VERSION_LESS 14)
  message(
    FATAL_ERROR
      "GCC >= 14 required, found ${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION}"
  )
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# Requires Lua
find_package(Lua REQUIRED)

# Everything lands in legacy/bin and legacy/lib (the portable part).
get_filename_component(LEGACY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Defines centralized output folders for testing/distribution.
set(LUA_DIST_DIR "${LEGACY_ROOT}/bin/dist/lua")

set(BINDING_WARN -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wconversion)
set(BINDING_HARDEN -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
                   -fstack-protector-strong)

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
  add_library(lua_extender_core MODULE src/lua_extender.c)

  target_compile_options(lua_extender_core PRIVATE ${BINDING_WARN}
                                                   ${BINDING_HARDEN})

  target_include_directories(
    lua_extender_core PRIVATE ${LUA_INCLUDE_DIR}
                              "${LEGACY_ROOT}/extender/include")

  target_link_libraries(lua_extender_core PRIVATE cpp_api)

  # Place the compiled library directly into the dist/ folder.
  set_target_properties(
    lua_extender_core
    PROPERTIES PREFIX "" # Remove the prefix 'lib' from C for the Lua directly
                         # (ex: lua_extender_core.so)
               C_VISIBILITY_PRESET hidden # only luaopen_* is exported
               LIBRARY_OUTPUT_DIRECTORY "${LUA_DIST_DIR}"
               BUILD_WITH_INSTALL_RPATH ON
               # INSTALL_RPATH "${LEGACY_ROOT}/lib")
               INSTALL_RPATH "\$ORIGIN/../../lib")

  # --- Copy (binding.lua and tests/*) to the dist/ folder. --------------------
  add_custom_target(
    lua_prepare_dist ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory "${LUA_DIST_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy
            "${CMAKE_CURRENT_SOURCE_DIR}/src/binding.lua" "${LUA_DIST_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/tests" "${LUA_DIST_DIR}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/binding.lua"
    COMMENT "Copying the Lua scripts to ${LUA_DIST_DIR}")
  add_dependencies(lua_prepare_dist lua_extender_core)

else()
  message(
    FATAL_ERROR
      "Lua not found. Please ensure the Lua library is installed on your system."
  )
endif()
