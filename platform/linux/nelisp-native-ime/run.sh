#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../../.." && pwd)
runtime=${NELISP_IME_RUNTIME:?set NELISP_IME_RUNTIME to the standalone runtime executable}
if [ ! -x "$runtime" ]; then
  echo "IME runtime is missing or not executable: $runtime" >&2
  exit 2
fi
out=${NELISP_IME_BUILD_DIR:-$here/build}
export NELISP_IME_ROOT=${NELISP_IME_ROOT:-$repo}
export NELISP_IME_ENTRY=${NELISP_IME_ENTRY:-$here/engine-entry.el}
sh "$here/build.sh"
exec "$out/native-ime"
