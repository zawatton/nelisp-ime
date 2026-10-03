#!/usr/bin/env python3
"""Drive the NeLisp IBus engine through a real, private ibus-daemon.

The harness owns Xvfb, a session D-Bus daemon, ibus-daemon and a GTK4
entry, registers the component from this source tree, types with xdotool
and checks the entry text.  Every owned process group is reaped.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent


def descendants(pid):
    found, queue = set(), [pid]
    while queue:
        current = queue.pop()
        children = Path(f'/proc/{current}/task/{current}/children')
        try:
            pids = [int(p) for p in children.read_text().split()]
        except OSError:
            continue
        found.update(pids)
        queue.extend(pids)
    return found


def stop(proc):
    if proc and proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=2)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=2)


def read_line(proc, timeout, what):
    if not select.select([proc.stdout], [], [], timeout)[0]:
        raise RuntimeError(what + ' did not start promptly')
    return proc.stdout.readline().strip()


def verify(output, mode, settle):
    output.mkdir(parents=True, exist_ok=True)
    state = output / 'state'
    env = dict(os.environ, GDK_BACKEND='x11', GSK_RENDERER='cairo', GTK_A11Y='none',
               GTK_IM_MODULE='ibus', GSETTINGS_BACKEND='memory', NO_AT_BRIDGE='1',
               XDG_CONFIG_HOME=str(state / 'config'), XDG_CACHE_HOME=str(state / 'cache'),
               XDG_DATA_HOME=str(state / 'data'))
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('IBUS_ADDRESS', None)
    for name in ('config', 'cache', 'data', 'component'):
        (state / name).mkdir(parents=True, exist_ok=True)
    component = (HERE / 'nelisp-ime.xml').read_text(encoding='utf-8')
    # ibus-daemon parses <exec> with g_shell_parse_argv and spawns it without a
    # PATH search; keep engine output for diagnosis.
    command = (f"/bin/sh -c 'exec {sys.executable} {HERE / 'ibus-engine-nelisp'} "
               f">>{output / 'engine.log'} 2>&1'")
    component, count = re.subn(r'<exec>[^<]*</exec>', lambda _: '<exec>' + escape(command) + '</exec>', component)
    if count != 1:
        raise RuntimeError('Component must have exactly one exec element')
    (state / 'component/nelisp-ime.xml').write_text(component, encoding='utf-8')
    env['IBUS_COMPONENT_PATH'] = str(state / 'component')
    owned, pids, checks = [], set(), []
    log = output / 'app.log'
    started = time.monotonic()

    def spawn(name, argv, **kwargs):
        stream = (output / (name + '.log')).open('w')
        proc = subprocess.Popen(argv, env=env, stderr=stream, start_new_session=True,
                                text=True, **kwargs)
        owned.append(proc)
        return proc

    def run(*argv, check=True):
        result = subprocess.run(list(argv), env=env, capture_output=True, text=True,
                                timeout=30)
        if check and result.returncode != 0:
            raise RuntimeError(f'{" ".join(argv)} failed ({result.returncode}): '
                               + (result.stderr or result.stdout).strip()[-300:])
        return result

    def entry_text():
        lines = re.findall(r'^TEXT: (.*)$', log.read_text(encoding='utf-8'), re.M)
        return lines[-1] if lines else ''

    def wait_for(predicate, timeout, what):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.05)
        raise RuntimeError(what)

    try:
        xserver = spawn('xserver', ['Xvfb', '-displayfd', '1', '-screen', '0', '800x600x24',
                                    '-nolisten', 'tcp'], stdout=subprocess.PIPE)
        env['DISPLAY'] = ':' + read_line(xserver, 5, 'Xvfb')
        bus = spawn('dbus', ['dbus-daemon', '--session', '--nofork', '--print-address=1'],
                    stdout=subprocess.PIPE)
        env['DBUS_SESSION_BUS_ADDRESS'] = read_line(bus, 5, 'D-Bus')
        daemon = spawn('ibus-daemon', ['ibus-daemon', '--single', '--cache=none',
                                       '--panel=disable', '--replace', '--verbose'],
                       stdout=subprocess.DEVNULL)
        wait_for(lambda: 'nelisp-ime' in run('ibus', 'list-engine', check=False).stdout,
                 10, 'ibus-daemon did not register the NeLisp component')
        checks.append('Component registered from the source tree')
        with log.open('w') as stdout:
            app = spawn('app', [sys.executable, str(HERE / 'desktop-entry-app.py')],
                        stdout=stdout)
            wait_for(lambda: 'APP_READY' in log.read_text(encoding='utf-8'), 10,
                     'GTK entry did not start')
            window = None
            deadline = time.monotonic() + 5
            while window is None and time.monotonic() < deadline:
                found = run('xdotool', 'search', '--onlyvisible', '--name',
                            '^NeLisp IBus Probe$', check=False).stdout.split()
                window = found[0] if found else None
                time.sleep(.05)
            if window is None:
                raise RuntimeError('GTK window did not appear')
            run('xdotool', 'windowfocus', '--sync', window)
            time.sleep(.3)
            if mode != 'control':
                # Select once and confirm through the daemon's own state: the CLI
                # also runs setxkbmap afterwards, whose exit status is unrelated.
                selected = time.monotonic()
                selector = subprocess.Popen(['ibus', 'engine', 'nelisp-ime'], env=env,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            text=True)
                if mode == 'early':
                    # Type while the engine (and NeLisp) is still starting.
                    time.sleep(1)
                    typed_early = time.monotonic()
                    for value in ['k', 'a', 'n', 'j', 'i', 'space', 'Return']:
                        run('xdotool', 'key', '--clearmodifiers', value)
                        time.sleep(.15)
                    early_seconds = round(time.monotonic() - typed_early, 3)
                    engine_log = output / 'engine.log'
                    ready_early = engine_log.exists() and                         'ENGINE_READY' in engine_log.read_text(encoding='utf-8')
                out, err = selector.communicate(timeout=90)
                result = subprocess.CompletedProcess(selector.args, selector.returncode, out, err)
                elapsed = round(time.monotonic() - selected, 3)
                (output / 'select.json').write_text(json.dumps(
                    {'seconds': elapsed, 'exit': result.returncode,
                     'output': (result.stderr + result.stdout).strip()[-300:]}, indent=1))
                wait_for(lambda: run('ibus', 'engine', check=False).stdout.strip()
                         == 'nelisp-ime', 5, 'NeLisp engine was not selected')
                checks.append(f'NeLisp engine selected; selection call took {elapsed} s')
            time.sleep(settle)
            keys = ['k', 'a', 'n', 'j', 'i', 'space', 'Return']
            if mode == 'early':
                if ready_early:
                    raise RuntimeError('NeLisp was ready before the early keys were typed; '
                                       'use a slower NELISP_IME_RUNTIME')
                checks.append(f'Typed {early_seconds} s of keys before the engine was ready')
            elif mode == 'burst':
                run('xdotool', 'key', '--clearmodifiers', '--delay', '1', *keys)
            else:
                for value in keys:
                    run('xdotool', 'key', '--clearmodifiers', value)
                    time.sleep(.15)
            expected = 'kanji ' if mode == 'control' else '幹事'
            try:
                wait_for(lambda: entry_text() == expected, 30,
                         'entry text mismatch')
            except RuntimeError:
                raise RuntimeError(f'Entry text {entry_text()!r}, expected {expected!r}')
            time.sleep(.5)
            if entry_text() != expected:
                raise RuntimeError(f'Entry text changed afterwards to {entry_text()!r}')
            checks.append(f'GTK4 entry text is {expected!r}')
            for proc in owned:
                pids.add(proc.pid)
                pids.update(descendants(proc.pid))
        return {'status': 'PASS', 'mode': mode, 'checks': checks,
                'elapsed_seconds': round(time.monotonic() - started, 3)}
    finally:
        for proc in owned:
            if proc.poll() is None:
                pids.add(proc.pid)
                pids.update(descendants(proc.pid))
        for proc in reversed(owned):
            stop(proc)
        deadline = time.monotonic() + 3
        while any(Path(f'/proc/{pid}').exists() for pid in pids) and time.monotonic() < deadline:
            time.sleep(.05)
        remaining = [pid for pid in pids if Path(f'/proc/{pid}').exists()]
        for pid in remaining:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if remaining:
            raise RuntimeError(f'Owned processes remained after teardown: {remaining}')
        checks.append(f'All {len(pids)} owned processes were reaped')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', default='convert', choices=['convert', 'control', 'burst', 'early'])
    parser.add_argument('--settle', type=float, default=0.0,
                        help='seconds to wait after selecting the engine before typing')
    args = parser.parse_args()
    result = verify(args.output.resolve(), args.mode, args.settle)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(result, ensure_ascii=False))
