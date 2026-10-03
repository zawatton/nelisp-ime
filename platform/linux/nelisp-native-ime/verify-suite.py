"""Build once and verify real conversion plus owned-process fault controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
source = args.source.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
runtime = env.get('NELISP_IME_RUNTIME')
if not runtime or not Path(runtime).is_file():
    raise SystemExit('Set NELISP_IME_RUNTIME to an actual standalone executable')
env['NELISP_IME_ENTRY'] = str(source / 'engine-entry.el')
env.setdefault('NELISP_IME_ROOT', str(source.parents[2]))
env.setdefault('NELISP_ROOT', str(source.parents[2].parent/'nelisp'))
env['NELISP_IME_BUILD_DIR'] = str(output / 'build')
env.pop('NATIVE_IME_CHECK_FUNCTION', None)
timings = {}

def step(name, command, timeout, overrides=None):
    started = time.monotonic()
    task_env = dict(env, **(overrides or {}))
    with (output / (name + '.log')).open('w') as log:
        subprocess.run(command, env=task_env, check=True, timeout=timeout,
                       stdout=log, stderr=subprocess.STDOUT)
    timings[name] = round(time.monotonic() - started, 3)
    print(name + ': PASS', flush=True)

step('structure', ['emacs', '-Q', '--batch', '-l', str(source/'check-aot-structure.el'),
                   '--', str(source/'native-ime.el')], 10)
step('structure-controls', [sys.executable, str(source/'verify-structure-controls.py'),
                           'emacs', str(source/'check-aot-structure.el'),
                           str(output/'structure-controls')], 45)
step('efficiency', [sys.executable, str(source/'measure-structure.py'),
                   str(source/'check-aot-structure.el'),
                   str(source.parent/'nelisp-native-probe/build-probe.el'),
                   str(output/'structure-controls/boxed.el'), str(output/'efficiency')],
     70, {'NELISP_PROBE_OUT_DIR': str(output/'efficiency')})
step('build', ['sh', str(source/'build.sh')], 70)
binary = output / 'build/native-ime'
verifier = source / 'verify-engine.py'
def gui(name, mode, overrides=None):
    step(name, [sys.executable, str(verifier), str(binary), str(output/name),
                '--mode', mode], 90, overrides)

gui('positive', 'positive')
gui('burst', 'burst')
fault = source / 'fault-runtime.py'
fault.chmod(fault.stat().st_mode | 0o100)
base_fault = {'NELISP_IME_RUNTIME': str(fault)}
gui('queue-overflow', 'queue-overflow', dict(base_fault, NATIVE_IME_FAULT='slow-first',
                                             NELISP_IME_RESPONSE_TIMEOUT_MS='5000'))
gui('startup-escape', 'startup-escape', dict(base_fault, NATIVE_IME_FAULT='startup-hang'))
gui('startup-failure', 'startup-failure', dict(base_fault, NATIVE_IME_FAULT='startup-hang',
                                             NELISP_IME_STARTUP_TIMEOUT_MS='1500'))
gui('response-escape', 'response-escape', dict(base_fault, NATIVE_IME_FAULT='response-hang',
                                              NELISP_IME_RESPONSE_TIMEOUT_MS='60000'))
for kind in ['response-hang', 'protocol-error', 'malformed', 'wrong-type', 'closed-stdin']:
    gui(kind, 'response-failure', dict(base_fault, NATIVE_IME_FAULT=kind,
                                       NELISP_IME_RESPONSE_TIMEOUT_MS='200'))
entry = (source/'engine-entry.el').read_text()
needle = r'\"op\":\"key\"'
if entry.count(needle) != 1:
    raise RuntimeError('Disabled-conversion control requires exactly one key operation')
disabled = output/'disabled-entry.el'
disabled.write_text(entry.replace(needle, r'\"op\":\"cancel\"'))
gui('negative', 'negative', {'NELISP_IME_ENTRY': str(disabled)})
result = {'status': 'PASS', 'runtime': runtime,
          'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'timings_seconds': timings,
          'source_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in source.iterdir() if p.is_file()}}
(output/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({'status': 'PASS', 'timings_seconds': timings}))
