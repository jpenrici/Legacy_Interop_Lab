# legacy/wrapper/cpp/CMakeLists.txt

cmake_minimum_required(VERSION 3.25 FATAL_ERROR)

project(legacy_extender CXX)

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
get_filename_component(LEGACY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

set(WRAPPER_WARN -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wconversion)
set(WRAPPER_HARDEN -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
                   -fstack-protector-strong)

# C++ Wrapper Library
add_library(legacy_cpp_wrapper src/legacy_wrapper.cpp)
set_target_properties(
  legacy_cpp_wrapper
  PROPERTIES OUTPUT_NAME _legacy_cpp_wrapper # -> lib_legacy_cpp_wrapper.so
             CXX_VISIBILITY_PRESET hidden
             LIBRARY_OUTPUT_DIRECTORY "${LEGACY_ROOT}/lib")

target_include_directories(legacy_cpp_wrapper PUBLIC include)
target_include_directories(legacy_cpp_wrapper PUBLIC include
                                                     ../../bridge/include)
target_compile_options(legacy_cpp_wrapper PRIVATE ${WRAPPER_WARN}
                                                  ${WRAPPER_HARDEN})
target_link_libraries(legacy_cpp_wrapper PRIVATE ${CMAKE_DL_LIBS})

# bin/legacy_wrapper_test : finds ../lib by itself, whatever the tree location.
add_executable(legacy_wrapper_test tests/main.cpp)
set_target_properties(
  legacy_wrapper_test
  PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${LEGACY_ROOT}/bin"
             BUILD_WITH_INSTALL_RPATH ON
             INSTALL_RPATH "\$ORIGIN/../lib")
target_compile_options(legacy_wrapper_test PRIVATE ${WRAPPER_WARN}
                                                   ${WRAPPER_HARDEN})
target_link_libraries(legacy_wrapper_test PRIVATE c_api)

enable_testing()
add_test(
  NAME legacy_wrapper_test
  COMMAND legacy_wrapper_test
  WORKING_DIRECTORY "${LEGACY_ROOT}/bin")
