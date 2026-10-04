cmake_minimum_required(VERSION 3.16)
project(legacy_bridge LANGUAGES C)

# The bridge requires GCC 14 or newer (the COBOL side has its own toolchain).
if(NOT CMAKE_C_COMPILER_ID STREQUAL "GNU" OR CMAKE_C_COMPILER_VERSION VERSION_LESS 14)
  message(FATAL_ERROR
    "GCC >= 14 required, found ${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION}")
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# Everything lands in legacy/bin and legacy/lib (the portable part).
get_filename_component(LEGACY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

set(BRIDGE_WARN -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wconversion)
set(BRIDGE_HARDEN -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fstack-protector-strong)

# lib/lib_c_api.so : only the symbols marked LG_API are exported.
add_library(c_api SHARED src/api.c)
set_target_properties(c_api PROPERTIES
  OUTPUT_NAME _c_api                       # -> lib_c_api.so
  C_VISIBILITY_PRESET hidden
  LIBRARY_OUTPUT_DIRECTORY "${LEGACY_ROOT}/lib")
target_include_directories(c_api PUBLIC include)
target_compile_options(c_api PRIVATE ${BRIDGE_WARN} ${BRIDGE_HARDEN})
target_link_libraries(c_api PRIVATE ${CMAKE_DL_LIBS})

# bin/c_api_test : finds ../lib by itself, whatever the tree location.
add_executable(c_api_test tests/main.c)
set_target_properties(c_api_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${LEGACY_ROOT}/bin"
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "\$ORIGIN/../lib")
target_compile_options(c_api_test PRIVATE ${BRIDGE_WARN} ${BRIDGE_HARDEN})
target_link_libraries(c_api_test PRIVATE c_api)

enable_testing()
add_test(NAME c_api_test COMMAND c_api_test
         WORKING_DIRECTORY "${LEGACY_ROOT}/bin")
