#!/usr/bin/env python3
"""Owned protocol fault process; never used as a successful engine substitute."""
import json
import os
from pathlib import Path
import sys
import time

mode = os.environ.get('NATIVE_IME_FAULT', 'startup-hang')
if os.environ.get('NATIVE_IME_PID_FILE'):
    Path(os.environ['NATIVE_IME_PID_FILE']).write_text(str(os.getpid()))
for number, line in enumerate(sys.stdin):
    if number == 0:
        if mode != 'startup-hang':
            print('READY', flush=True)
        if mode == 'closed-stdin':
            os.close(0)
            while True:
                time.sleep(1)
    elif mode == 'slow-first':
        # Queue-bound control: hold the first request so later keys queue,
        # then echo each key with its sequence number as a non-converting preedit.
        if number == 1:
            time.sleep(2)
        key = line.split('"')[3] if line.count('"') >= 4 else '?'
        print(json.dumps({'jsonrpc':'2.0','id':number,'result':
                          {'preedit':key + str(number),'candidates':[],'commit':None}}),
              flush=True)
    elif mode == 'protocol-error':
        print(json.dumps({'jsonrpc':'2.0','id':1,'error':
                          {'code':-32603,'message':'injected engine failure'}}), flush=True)
    elif mode == 'malformed':
        print('{invalid-json', flush=True)
    elif mode == 'wrong-type':
        print(json.dumps({'jsonrpc':'2.0','id':1,'result':[]}), flush=True)
