#!/bin/sh
# Build and exercise GTK callbacks without modifying the compiler checkout.
set -eu
probe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir=${NELISP_PROBE_OUT_DIR:-"$probe_dir/build/verification"}
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
export NELISP_PROBE_OUT_DIR="$output_dir"
unset NELISP_PROBE_OBJECT
timeout 45 emacs -Q --batch -l "$probe_dir/build-probe.el" -- \
    "$probe_dir/native-probe.el" > "$output_dir/build.log" 2>&1
gcc "$output_dir/native-probe.o" $(pkg-config --libs gtk4) -o "$output_dir/native-probe"
python3 "$probe_dir/verify-probe.py" "$output_dir/native-probe" "$output_dir/positive"
python3 - "$probe_dir/native-probe.el" "$output_dir/disabled-callback.el" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
signal = '(extern-call g_signal_connect_data keys (data-addr sig_key) (addr-of on_key) ctx 0 0)'
if source.count(signal) != 1:
    raise SystemExit('Expected exactly one key callback registration')
Path(sys.argv[2]).write_text(source.replace(signal, '0'))
PY
NELISP_PROBE_OBJECT="$output_dir/disabled-callback.o" timeout 45 emacs -Q --batch \
    -l "$probe_dir/build-probe.el" -- "$output_dir/disabled-callback.el" \
    > "$output_dir/negative-build.log" 2>&1
gcc "$output_dir/disabled-callback.o" $(pkg-config --libs gtk4) -o "$output_dir/disabled-callback"
python3 "$probe_dir/verify-probe.py" "$output_dir/disabled-callback" \
    "$output_dir/negative" --negative
python3 "$probe_dir/verify-probe.py" "$output_dir/native-probe" \
    "$output_dir/close-request" --close-request
