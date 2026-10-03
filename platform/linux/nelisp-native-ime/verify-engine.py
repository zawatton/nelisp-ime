"""Exercise native GTK widgets backed by an owned IME process."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import select
import signal
import subprocess
import time


def stop(proc):
    if proc and proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=2)


def run(command, env):
    return subprocess.run(command, env=env, check=True, capture_output=True,
                          text=True, timeout=3).stdout.strip()


def verify(binary, output, mode):
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, GDK_BACKEND='x11', GSK_RENDERER='cairo',
               GTK_IM_MODULE='simple', GTK_A11Y='none')
    env.pop('WAYLAND_DISPLAY', None)
    xserver = app = None
    checks = []
    consumed = 0
    child_pids = set()
    log = output / 'stdout.log'
    started = time.monotonic()
    try:
        with (output / 'xserver.log').open('w') as stderr:
            xserver = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0',
                                       '800x600x24', '-nolisten', 'tcp'],
                                      stdout=subprocess.PIPE, stderr=stderr,
                                      text=True, start_new_session=True)
            if not select.select([xserver.stdout], [], [], 5)[0]:
                raise RuntimeError('Owned X server startup timed out')
            env['DISPLAY'] = ':' + xserver.stdout.readline().strip()
        with log.open('w') as stdout, (output / 'stderr.log').open('w') as stderr:
            app = subprocess.Popen([str(binary)], env=env, stdout=stdout,
                                   stderr=stderr, start_new_session=True)

            def text():
                return log.read_text(encoding='utf-8')

            def expect(value, timeout=4):
                nonlocal consumed
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    match = text().find(value, consumed)
                    if match >= 0:
                        consumed = match + len(value)
                        checks.append(value.rstrip())
                        return
                    if app.poll() is not None:
                        break
                    time.sleep(.02)
                raise RuntimeError('Widget trace missing: ' + value.rstrip())

            deadline = time.monotonic() + 5
            window = None
            while time.monotonic() < deadline:
                result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name',
                                         '^NeLisp GTK4 IME$'], env=env, text=True,
                                        capture_output=True, timeout=2)
                if result.returncode == 0 and result.stdout.strip():
                    window = result.stdout.splitlines()[0]
                    break
                if app.poll() is not None:
                    break
                time.sleep(.03)
            if window is None:
                raise RuntimeError('GTK window did not appear promptly')
            children = Path(f'/proc/{app.pid}/task/{app.pid}/children')
            if children.exists():
                child_pids.update(map(int, children.read_text().split()))
            child_pids.update(int(pid) for pid in re.findall(r'^ENGINE_PID: ([0-9]+)$', text(), re.M))
            if not child_pids:
                raise RuntimeError('No owned engine process was observed')
            run(['xdotool', 'windowfocus', '--sync', window], env)

            def key(value):
                run(['xdotool', 'key', '--clearmodifiers', value], env)

            if mode == 'startup-escape':
                before = time.monotonic()
                key('Escape')
                if app.wait(timeout=2) != 0:
                    raise RuntimeError('Escape failed during startup')
                checks.append('Escape during startup returns within two seconds')
            elif mode == 'startup-failure':
                expect('ENGINE_ERROR: startup timeout', 3)
                app.wait(timeout=2)
                checks.append('Startup failure is bounded')
            else:
                expect('ENGINE_READY\n', 65)
                if mode == 'response-escape':
                    key('k')
                    time.sleep(.05)
                    key('Escape')
                    if app.wait(timeout=2) != 0:
                        raise RuntimeError('Escape failed during pending response')
                    checks.append('Escape interrupts a pending response within two seconds')
                elif mode == 'burst':
                    # One xdotool call with a 1 ms delay lands keys while the
                    # previous request is still pending; nothing may be lost.
                    run(['xdotool', 'key', '--clearmodifiers', '--delay', '1',
                         'k', 'a', 'n', 'j', 'i', 'space', 'Return'], env)
                    expect('PREEDIT: 漢字\n', 15)
                    expect('PREEDIT: 幹事\n', 5)
                    expect('COMMIT: 幹事\n', 5)
                    if 'QUEUE_FULL' in text() or 'ENGINE_ERROR:' in text():
                        raise RuntimeError('Burst input overflowed or failed')
                    key('Escape')
                    if app.wait(timeout=3) != 0:
                        raise RuntimeError('Normal GTK exit failed')
                    checks.append('Burst-typed kanji, Space and Enter commit in order')
                elif mode == 'queue-overflow':
                    typed = [chr(ord('a') + n % 26) for n in range(80)]
                    run(['xdotool', 'key', '--clearmodifiers', '--delay', '1'] + typed, env)
                    accepted = typed[:65]
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if len(re.findall(r'^PREEDIT: ', text(), re.M)) >= 65:
                            break
                        if app.poll() is not None:
                            break
                        time.sleep(.05)
                    time.sleep(.3)
                    seen = re.findall(r'^PREEDIT: ([a-z])[0-9]+$', text(), re.M)
                    if seen != accepted:
                        raise RuntimeError('Queued keys were not processed exactly in order: '
                                           + ''.join(seen))
                    if text().count('QUEUE_FULL\n') != len(typed) - len(accepted):
                        raise RuntimeError('Overflow count mismatch')
                    if 'ENGINE_ERROR:' in text():
                        raise RuntimeError('Queued processing reported an engine error')
                    key('Escape')
                    if app.wait(timeout=3) != 0:
                        raise RuntimeError('Normal GTK exit failed')
                    checks.append('64 queued keys follow the in-flight key in order; '
                                  'the remaining 15 report QUEUE_FULL')
                elif mode == 'response-failure':
                    key('k')
                    expect('ENGINE_ERROR:', 3)
                    app.wait(timeout=2)
                    checks.append('Pending response failure is bounded')
                else:
                    if mode == 'positive':
                        before = text().count('PREEDIT:')
                        key('ctrl+a')
                        key('alt+a')
                        key('space')
                        time.sleep(.15)
                        if text().count('PREEDIT:') != before or 'ENGINE_ERROR:' in text():
                            raise RuntimeError('Modifier or empty-candidate key changed engine state')
                        checks.append('Ctrl/Alt and empty-candidate Space pass through')
                    for value in 'kanji':
                        key(value)
                        if mode == 'negative':
                            time.sleep(.15)
                        else:
                            expected = {'k':'k', 'a':'\u304b', 'n':'\u304bn',
                                        'j':'\u7f36j', 'i':'\u6f22\u5b57'}[value]
                            expect('PREEDIT: ' + expected + '\n')
                    if mode == 'negative':
                        expect('PREEDIT: \u6f22\u5b57\n', 2)
                        raise RuntimeError('Disabled conversion unexpectedly passed')
                    expect('CANDIDATES: \u6f22\u5b57')
                    run(['xwd', '-silent', '-id', window, '-out', str(output/'candidates.xwd')], env)
                    run(['convert', str(output/'candidates.xwd'), str(output/'candidates.png')], env)
                    key('space')
                    expect('PREEDIT: \u5e79\u4e8b\n')
                    expect('CANDIDATES: \u5e79\u4e8b')
                    key('Return')
                    expect('COMMIT: \u5e79\u4e8b\n')
                    key('k')
                    expect('PREEDIT: k\n')
                    key('a')
                    expect('PREEDIT: \u304b\n')
                    key('BackSpace')
                    expect('PREEDIT: \n')
                    run(['xwd', '-silent', '-id', window, '-out', str(output/'commit.xwd')], env)
                    run(['convert', str(output/'commit.xwd'), str(output/'commit.png')], env)
                    key('Escape')
                    if app.wait(timeout=3) != 0:
                        raise RuntimeError('Normal GTK exit failed')
                    checks.append('Commit, next input and backspace complete')
        return {'status':'PASS', 'mode':mode, 'checks':checks,
                'elapsed_seconds':round(time.monotonic()-started, 3)}
    except RuntimeError as error:
        if mode == 'negative' and str(error) == 'Widget trace missing: PREEDIT: \u6f22\u5b57':
            return {'status':'EXPECTED_FAILURE','mode':mode,'reason':str(error)}
        raise
    finally:
        stop(app)
        stop(xserver)
        deadline = time.monotonic() + 2
        while any(Path(f'/proc/{pid}').exists() for pid in child_pids) and time.monotonic() < deadline:
            time.sleep(.02)
        remaining = [pid for pid in child_pids if Path(f'/proc/{pid}').exists()]
        if remaining:
            for pid in remaining:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            raise RuntimeError(f'Owned engine children remained after exit: {remaining}')
        checks.append('Owned engine process was reaped')
        errors = output / 'stderr.log'
        if errors.exists() and 'CRITICAL' in errors.read_text(encoding='utf-8'):
            raise RuntimeError('Native GTK/GLib emitted a critical API warning')


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', default='positive', choices=[
        'positive','negative','burst','queue-overflow','startup-escape','startup-failure','response-failure','response-escape'])
    args = parser.parse_args()
    result = verify(args.binary.resolve(), args.output.resolve(), args.mode)
    (args.output/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
