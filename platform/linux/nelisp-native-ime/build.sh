#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../../.." && pwd)
compiler_root=${NELISP_ROOT:-$repo/../nelisp}
out=${NELISP_IME_BUILD_DIR:-$here/build}
mkdir -p "$out"
NELISP_ROOT=$compiler_root NELISP_PROBE_OUT_DIR=$out \
NELISP_PROBE_OBJECT=$out/native-ime.o \
  timeout 45s emacs -Q --batch -l "$repo/platform/linux/nelisp-native-probe/build-probe.el" \
    -- "$here/native-ime.el"
timeout 20s gcc "$out/native-ime.o" $(pkg-config --cflags --libs gtk4 gio-2.0 json-glib-1.0) \
  -o "$out/native-ime"
echo "Built $out/native-ime"
