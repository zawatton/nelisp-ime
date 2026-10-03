#!/usr/bin/env python3
"""Run every IBus desktop mode against the real NeLisp runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--slow-start', type=float, default=8.0,
                    help='seconds the early mode delays NeLisp startup')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
runtime = os.environ.get('NELISP_IME_RUNTIME')
if not runtime or not Path(runtime).is_file():
    raise SystemExit('Set NELISP_IME_RUNTIME to an actual standalone executable')
os.environ.setdefault('NELISP_IME_ROOT', str(HERE.parents[2]))
slow = output / 'slow-nelisp'
slow.write_text(f'#!/bin/sh\nsleep {args.slow_start}\nexec "{runtime}" "$@"\n')
slow.chmod(0o755)
results = {}
for mode, overrides in [('control', {}), ('convert', {}), ('burst', {}),
                        ('early', {'NELISP_IME_RUNTIME': str(slow)})]:
    target = output / mode
    completed = subprocess.run([sys.executable, str(HERE / 'verify-desktop.py'), str(target),
                                '--mode', mode], env=dict(os.environ, **overrides),
                               timeout=180, capture_output=True, text=True)
    (output / (mode + '.log')).write_text(completed.stdout + completed.stderr)
    if completed.returncode != 0:
        raise SystemExit(f'{mode}: FAIL\n' + (completed.stdout + completed.stderr)[-600:])
    results[mode] = json.loads((target / 'result.json').read_text(encoding='utf-8'))
    print(mode + ': PASS', flush=True)
summary = {'status': 'PASS', 'runtime': runtime,
           'runtime_sha256': hashlib.sha256(Path(runtime).read_bytes()).hexdigest(),
           'modes': results,
           'source_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in sorted(HERE.iterdir()) if p.is_file()}}
(output / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False) + '\n')
print(json.dumps({'status': 'PASS', 'modes': list(results)}))
