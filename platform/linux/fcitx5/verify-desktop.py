#!/usr/bin/env python3
"""Drive the NeLisp Fcitx 5 addon through a real, private fcitx5 process.

The harness owns Xvfb, a session D-Bus daemon, fcitx5 and a GTK4 entry,
loads the addon from a build directory, types with xdotool and checks the
entry text.  Every owned process is reaped.  FCITX5_PREFIX selects a
Fcitx 5 installation other than /usr (for example an unpacked one).
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
APP = HERE.parent / 'ibus' / 'desktop-entry-app.py'
KEYS = ['k', 'a', 'n', 'j', 'i', 'space', 'Return']
KANJI = '幹事'
PROFILE = """[Groups/0]
Name=Default
Default Layout=us
DefaultIM=nelisp-ime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=nelisp-ime
Layout=

[GroupOrder]
0=Default
"""
DISABLED = ('classicui,kimpanel,notificationitem,notifications,clipboard,emoji,'
            'quickphrase,unicode,spell,xim,wayland,waylandim,virtualkeyboard,'
            'fcitx4frontend,ibusfrontend,imselector')


def descendants(pid):
    found, queue = set(), [pid]
    while queue:
        current = queue.pop()
        try:
            pids = [int(p) for p in Path(f'/proc/{current}/task/{current}/children')
                    .read_text().split()]
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


def verify(output, addon, mode):
    prefix = Path(os.environ.get('FCITX5_PREFIX', '/usr'))
    libdir = prefix / 'lib/x86_64-linux-gnu'
    output.mkdir(parents=True, exist_ok=True)
    state = output / 'state'
    share = state / 'share/fcitx5'
    for sub in ('addon', 'inputmethod'):
        (share / sub).mkdir(parents=True, exist_ok=True)
    shutil.copy(addon / 'nelisp-ime-addon.conf', share / 'addon/nelisp-ime.conf')
    shutil.copy(addon / 'nelisp-ime.conf', share / 'inputmethod/nelisp-ime.conf')
    (state / 'config/fcitx5').mkdir(parents=True, exist_ok=True)
    (state / 'config/fcitx5/profile').write_text(PROFILE)
    env = dict(os.environ, GDK_BACKEND='x11', GSK_RENDERER='cairo', GTK_A11Y='none',
               GTK_IM_MODULE='fcitx', GSETTINGS_BACKEND='memory', NO_AT_BRIDGE='1',
               XDG_CONFIG_HOME=str(state / 'config'), XDG_CACHE_HOME=str(state / 'cache'),
               XDG_DATA_HOME=str(state / 'data'),
               XDG_DATA_DIRS=':'.join([str(state / 'share'), str(prefix / 'share'),
                                       '/usr/share']),
               FCITX_ADDON_DIRS=':'.join([str(addon), str(libdir / 'fcitx5')]),
               # GTK 4 scans $GTK_PATH/4.0.0/immodules.
               GTK_PATH=str(libdir / 'gtk-4.0'),
               LD_LIBRARY_PATH=':'.join(filter(None, [str(libdir),
                                                      os.environ.get('LD_LIBRARY_PATH')])))
    env.pop('WAYLAND_DISPLAY', None)
    fcitx_bin = str(prefix / 'bin/fcitx5')
    remote = str(prefix / 'bin/fcitx5-remote')
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

    def expect_text(expected, timeout=30):
        try:
            wait_for(lambda: entry_text() == expected, timeout, 'entry text mismatch')
        except RuntimeError:
            raise RuntimeError(f'Entry text {entry_text()!r}, expected {expected!r}')
        time.sleep(.5)
        if entry_text() != expected:
            raise RuntimeError(f'Entry text changed afterwards to {entry_text()!r}')
        checks.append(f'GTK4 entry text is {expected!r}')

    def type_keys(keys, burst=False):
        if burst:
            run('xdotool', 'key', '--clearmodifiers', '--delay', '1', *keys)
            return
        for value in keys:
            run('xdotool', 'key', '--clearmodifiers', value)
            time.sleep(.15)

    def runtimes():
        return [pid for pid in descendants(fcitx.pid)
                if Path(f'/proc/{pid}/comm').read_text().strip() == 'nelisp']

    try:
        xserver = spawn('xserver', ['Xvfb', '-displayfd', '1', '-screen', '0', '800x600x24',
                                    '-nolisten', 'tcp'], stdout=subprocess.PIPE)
        env['DISPLAY'] = ':' + read_line(xserver, 5, 'Xvfb')
        bus = spawn('dbus', ['dbus-daemon', '--session', '--nofork', '--print-address=1'],
                    stdout=subprocess.PIPE)
        env['DBUS_SESSION_BUS_ADDRESS'] = read_line(bus, 5, 'D-Bus')
        fcitx = spawn('fcitx5', [fcitx_bin, '--replace', '--disable=' + DISABLED,
                                 '--verbose=*=4'], stdout=subprocess.DEVNULL)
        # fcitx5-remote exits non-zero until fcitx5 owns its D-Bus name; the
        # printed state stays 0 until an input context is focused.
        wait_for(lambda: run(remote, check=False).returncode == 0, 10,
                 'fcitx5 did not come up on the private bus')
        checks.append('fcitx5 running on the private bus with the source-built addon dir')
        with log.open('w') as stdout:
            spawn('app', [sys.executable, str(APP)], stdout=stdout)
            wait_for(lambda: 'APP_READY' in log.read_text(encoding='utf-8'), 10,
                     'GTK entry did not start')
            found = []
            wait_for(lambda: found.extend(run('xdotool', 'search', '--onlyvisible', '--name',
                                              '^NeLisp IBus Probe$',
                                              check=False).stdout.split()) or found,
                     5, 'GTK window did not appear')
            run('xdotool', 'windowfocus', '--sync', found[0])
            time.sleep(.5)
            if mode == 'control':
                run(remote, '-c')
                wait_for(lambda: run(remote, check=False).stdout.strip() == '1', 5,
                         'fcitx5 did not deactivate')
            else:
                run(remote, '-o')
                run(remote, '-s', 'nelisp-ime')
                wait_for(lambda: run(remote, '-n', check=False).stdout.strip()
                         == 'nelisp-ime', 5, 'NeLisp input method was not selected')
                checks.append('NeLisp input method active on the focused context')
            if mode == 'control':
                type_keys(KEYS)
                expect_text('kanji ')
            elif mode in ('convert', 'burst'):
                # The addon starts NeLisp off the callback thread; give it time.
                wait_for(lambda: bool(runtimes()), 10, 'NeLisp runtime was not started')
                time.sleep(6)
                type_keys(KEYS, burst=mode == 'burst')
                expect_text(KANJI)
            elif mode == 'early':
                # Type immediately while a deliberately slowed runtime starts:
                # nothing may leak into the entry, and the held keys convert.
                type_keys(KEYS)
                early = entry_text()
                (output / 'early.json').write_text(json.dumps({'text': early}))
                if early:
                    raise RuntimeError(f'Keys leaked while NeLisp was starting: {early!r}')
                checks.append('No text leaked while NeLisp was starting')
                expect_text(KANJI, 40)
            elif mode == 'recover':
                wait_for(lambda: bool(runtimes()), 10, 'NeLisp runtime was not started')
                time.sleep(6)
                type_keys(KEYS)
                expect_text(KANJI)
                victims = runtimes()
                for pid in victims:
                    os.kill(pid, signal.SIGKILL)
                checks.append(f'Killed NeLisp runtime {victims}')
                type_keys(['x'])
                wait_for(lambda: runtimes() and set(runtimes()) != set(victims), 15,
                         'NeLisp runtime was not restarted')
                time.sleep(6)
                type_keys(['BackSpace'])
                expect_text(KANJI, 5)
                # The first commit taught 幹事, so it is now the first candidate.
                type_keys(['k', 'a', 'n', 'j', 'i', 'Return'])
                expect_text(KANJI + KANJI)
                checks.append('Same fcitx5 process converted again after recovery, '
                              'with the learned candidate order')
            for proc in owned:
                pids.add(proc.pid)
                pids.update(descendants(proc.pid))
        if fcitx.poll() is not None:
            raise RuntimeError('fcitx5 exited during the run')
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
    parser.add_argument('addon', type=Path, help='build directory containing nelisp-ime.so')
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', default='convert',
                        choices=['control', 'convert', 'burst', 'early', 'recover'])
    args = parser.parse_args()
    result = verify(args.output.resolve(), args.addon.resolve(), args.mode)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(result, ensure_ascii=False))
