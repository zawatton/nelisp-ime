cmake_minimum_required(VERSION 3.16)
project(nelisp-ime-linux VERSION 0.1.0 LANGUAGES CXX)

set(NELISP_IME_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." CACHE PATH "NeLisp source root")
set(NELISP_IME_RUNTIME "${NELISP_IME_REPO_ROOT}/target/nelisp" CACHE FILEPATH "Standalone NeLisp executable")
if(NOT EXISTS "${NELISP_IME_RUNTIME}")
  message(FATAL_ERROR "Build standalone NeLisp first: make standalone-reader")
endif()

add_subdirectory(fcitx5)

install(PROGRAMS "${NELISP_IME_RUNTIME}" DESTINATION libexec/nelisp-ime)
install(PROGRAMS ibus/ibus-engine-nelisp DESTINATION libexec)
install(FILES ibus/nelisp_client.py DESTINATION libexec)
install(FILES ibus/nelisp-ime.xml DESTINATION share/ibus/component)
install(FILES
  "${NELISP_IME_REPO_ROOT}/packages/nelisp-json/src/nelisp-json.el"
  DESTINATION share/nelisp-ime/nelisp-root/packages/nelisp-json/src)
install(FILES
  "${NELISP_IME_REPO_ROOT}/packages/nelisp-ime/src/nelisp-ime-input.el"
  "${NELISP_IME_REPO_ROOT}/packages/nelisp-ime/src/nelisp-ime.el"
  "${NELISP_IME_REPO_ROOT}/packages/nelisp-ime/src/nelisp-ime-lattice.el"
  "${NELISP_IME_REPO_ROOT}/packages/nelisp-ime/src/nelisp-ime-protocol.el"
  DESTINATION share/nelisp-ime/nelisp-root/packages/nelisp-ime/src)
install(FILES
  "${NELISP_IME_REPO_ROOT}/packages/nelisp-ime/data/nelisp-ime-dictionary-data.el"
  DESTINATION share/nelisp-ime/nelisp-root/packages/nelisp-ime/data)
