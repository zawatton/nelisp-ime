"""Measure early rejection against the same failing AOT/link input."""
import argparse
import os
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('checker', type=Path)
parser.add_argument('driver', type=Path)
parser.add_argument('fixture', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
results = {}
for name, command, expected in [
    ('aot_link_rejection', ['emacs', '-Q', '--batch', '-l', str(args.driver),
                            '--', str(args.fixture)], 'nl_alloc'),
    ('structure_rejection', ['emacs', '-Q', '--batch', '-l', str(args.checker),
                              '--', str(args.fixture)], 'Inline boxed string')]:
    started = time.monotonic()
    with (args.output/(name+'.log')).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=45)
        if name == 'aot_link_rejection' and result.returncode == 0:
            obj = Path(os.environ['NELISP_PROBE_OUT_DIR'])/'native-probe.o'
            libraries = subprocess.check_output(['pkg-config', '--libs', 'glib-2.0'],
                                                text=True).split()
            result = subprocess.run(['gcc', str(obj), *libraries,
                                     '-o', str(args.output/'boxed-control')],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=20)
    elapsed = time.monotonic()-started
    if result.returncode == 0 or expected not in (args.output/(name+'.log')).read_text():
        raise RuntimeError('Expected exact rejection was not observed: '+name)
    results[name] = {'exit_code': result.returncode, 'seconds': round(elapsed, 4)}
results['status'] = 'PASS'
(args.output/'result.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results))
