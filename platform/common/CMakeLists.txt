cmake_minimum_required(VERSION 3.16)
project(nelisp-ime-common-smoke LANGUAGES CXX)
add_executable(nelisp-ime-common-smoke nelisp_ime_client.cpp smoke.cpp)
target_compile_features(nelisp-ime-common-smoke PRIVATE cxx_std_17)
if(MSVC)
  # /utf-8 keeps the UTF-8 Japanese string literals in smoke.cpp intact on
  # hosts whose ANSI codepage is double-byte (e.g. cp932), where the default
  # source-charset guess corrupts the literals and breaks brace balance.
  target_compile_options(nelisp-ime-common-smoke PRIVATE /W4 /WX /utf-8)
else()
  target_compile_options(nelisp-ime-common-smoke PRIVATE -Wall -Wextra -Werror)
endif()
