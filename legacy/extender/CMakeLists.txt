# legacy/extender/CMakeLists.txt

cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(legacy_extender LANGUAGES CXX)

# The wrapper requires GCC 14 or newer.
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

# Import C library
add_library(c_api SHARED IMPORTED)
set_target_properties(c_api PROPERTIES IMPORTED_LOCATION
                                       "${LEGACY_ROOT}/lib/lib_c_api.so")

# C++ Wrapper Library
add_library(legacy_cpp_wrapper SHARED src/legacy_extender.cpp)
set_target_properties(
  legacy_cpp_wrapper
  PROPERTIES OUTPUT_NAME _cpp_api # -> lib_cpp_api.so
             # CXX_VISIBILITY_PRESET hidden
             LIBRARY_OUTPUT_DIRECTORY "${LEGACY_ROOT}/lib")

target_include_directories(legacy_cpp_wrapper PUBLIC include ../bridge/include)

target_compile_options(legacy_cpp_wrapper PRIVATE ${WRAPPER_WARN}
                                                  ${WRAPPER_HARDEN})

# Links the wrapper to the C API and system dependencies
target_link_libraries(legacy_cpp_wrapper PRIVATE c_api ${CMAKE_DL_LIBS})

# Test Executable
add_executable(cpp_extender_test tests/main.cpp)
set_target_properties(
  cpp_extender_test
  PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${LEGACY_ROOT}/bin"
             BUILD_WITH_INSTALL_RPATH ON
             INSTALL_RPATH "\$ORIGIN/../lib")

target_compile_options(cpp_extender_test PRIVATE ${WRAPPER_WARN}
                                                 ${WRAPPER_HARDEN})

# # Links the test to the C++ wrapper
target_link_libraries(cpp_extender_test PRIVATE legacy_cpp_wrapper stdc++)

enable_testing()
add_test(
  NAME cpp_extender_test
  COMMAND cpp_extender_test
  WORKING_DIRECTORY "${LEGACY_ROOT}/bin")
