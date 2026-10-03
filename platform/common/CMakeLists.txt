cmake_minimum_required(VERSION 3.16)
project(nelisp-ime-common-smoke LANGUAGES CXX)
find_package(Threads REQUIRED)
add_executable(nelisp-ime-common-smoke nelisp_ime_client.cpp smoke.cpp)
add_executable(nelisp-ime-fault-runtime fault_runtime.cpp)
add_executable(nelisp-ime-fault-smoke nelisp_ime_client.cpp fault_smoke.cpp)
target_link_libraries(nelisp-ime-common-smoke PRIVATE Threads::Threads)
target_link_libraries(nelisp-ime-fault-runtime PRIVATE Threads::Threads)
target_link_libraries(nelisp-ime-fault-smoke PRIVATE Threads::Threads)
target_compile_features(nelisp-ime-common-smoke PRIVATE cxx_std_17)
target_compile_features(nelisp-ime-fault-runtime PRIVATE cxx_std_17)
target_compile_features(nelisp-ime-fault-smoke PRIVATE cxx_std_17)
if(MSVC)
  # /utf-8 keeps the UTF-8 Japanese string literals in smoke.cpp intact on
  # hosts whose ANSI codepage is double-byte (e.g. cp932), where the default
  # source-charset guess corrupts the literals and breaks brace balance.
  foreach(target nelisp-ime-common-smoke nelisp-ime-fault-runtime nelisp-ime-fault-smoke)
    target_compile_options(${target} PRIVATE /W4 /WX /utf-8)
  endforeach()
  # The fault runtime reads its mode with std::getenv, which /WX would
  # otherwise reject through C4996.
  target_compile_definitions(nelisp-ime-fault-runtime PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  foreach(target nelisp-ime-common-smoke nelisp-ime-fault-runtime nelisp-ime-fault-smoke)
    target_compile_options(${target} PRIVATE -Wall -Wextra -Werror)
  endforeach()
endif()
enable_testing()
add_test(NAME nelisp-ime-fault-smoke
  COMMAND nelisp-ime-fault-smoke $<TARGET_FILE:nelisp-ime-fault-runtime>)
set_tests_properties(nelisp-ime-fault-smoke PROPERTIES TIMEOUT 8)
