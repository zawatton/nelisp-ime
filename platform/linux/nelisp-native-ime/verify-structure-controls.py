"""Prove the source checker rejects the defects it claims to detect."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('emacs')
parser.add_argument('checker', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
names = ['fail-engine', 'json-member-object', 'json-member-string', 'json-member-array',
         'render-candidates', 'render-json', 'render-response', 'queue-request',
         'dispatch-key', 'enqueue-key', 'drain-keys', 'on_key', 'on_close', 'on_poll', 'main']
controls = {
    'nested': ('(seq (defun nested () 0))', 'Nested callback'),
    'boxed': ('(extern-call g_getenv "X")', 'Inline boxed string'),
    'body': ('(let ((x (extern-call g_get_monotonic_time))) (extern-call g_print x) x)',
             'Raw let needs one body'),
    'pointer': ('(ptr-write-u8 0 1)', 'Invalid pointer write'),
}
results = []
for name, (body, diagnostic) in controls.items():
    source = args.output / (name + '.el')
    source.write_text('(seq (defun print-label () ' + body + ') ' +
                      ' '.join('(defun %s () %s)' % (symbol, '(print-label)' if symbol == 'main' else '0')
                               for symbol in names) + ')\n')
    result = subprocess.run([args.emacs, '-Q', '--batch', '-l', str(args.checker.resolve()),
                             '--', str(source.resolve())], timeout=10,
                            text=True, capture_output=True)
    (args.output / (name + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode == 0 or diagnostic not in result.stdout:
        raise RuntimeError('Source checker control did not fail correctly: ' + name)
    results.append({'control':name, 'exit_code':result.returncode, 'diagnostic':diagnostic})
(args.output / 'result.json').write_text(json.dumps({'status':'PASS', 'controls':results}, indent=2)+'\n')
print(json.dumps(results))
