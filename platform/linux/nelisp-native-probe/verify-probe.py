"""Validate actual GTK callbacks on an owned, isolated X server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(args, env=None, timeout=15):
    return subprocess.run(args, env=env, check=True, capture_output=True,
                          text=True, timeout=timeout).stdout.strip()


def stop(proc):
    if proc and proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=2)


def request_close(display_name, window):
    """Send WM_DELETE_WINDOW without relying on a window manager."""
    import ctypes as c
    lib = c.CDLL('libX11.so.6')

    class Data(c.Union):
        _fields_ = [('values', c.c_long * 5)]

    class Message(c.Structure):
        _fields_ = [('type', c.c_int), ('serial', c.c_ulong),
                    ('send_event', c.c_int), ('display', c.c_void_p),
                    ('window', c.c_ulong), ('message_type', c.c_ulong),
                    ('format', c.c_int), ('data', Data)]

    class Event(c.Union):
        _fields_ = [('message', Message), ('padding', c.c_long * 24)]

    lib.XOpenDisplay.argtypes = [c.c_char_p]
    lib.XOpenDisplay.restype = c.c_void_p
    lib.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
    lib.XInternAtom.restype = c.c_ulong
    lib.XSendEvent.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_long,
                              c.POINTER(Event)]
    lib.XFlush.argtypes = [c.c_void_p]
    lib.XCloseDisplay.argtypes = [c.c_void_p]
    display = lib.XOpenDisplay(display_name.encode())
    if not display:
        raise RuntimeError('Could not open owned X display')
    try:
        event = Event()
        event.message.type = 33
        event.message.display = display
        event.message.window = int(window)
        event.message.message_type = lib.XInternAtom(display, b'WM_PROTOCOLS', 0)
        event.message.format = 32
        event.message.data.values[0] = lib.XInternAtom(display, b'WM_DELETE_WINDOW', 0)
        if not lib.XSendEvent(display, int(window), 0, 0, c.byref(event)):
            raise RuntimeError('Could not send close request')
        lib.XFlush(display)
    finally:
        lib.XCloseDisplay(display)


def verify(binary, output, negative=False, close_request=False):
    output.mkdir(parents=True, exist_ok=True)
    xserver = app = None
    env = dict(os.environ)
    env.pop('WAYLAND_DISPLAY', None)
    env.update(GDK_BACKEND='x11', GSK_RENDERER='cairo', GTK_IM_MODULE='simple')
    deadline = time.monotonic() + 20
    checks = []
    consumed = 0
    log = output / 'stdout.log'
    try:
        with (output / 'xserver.log').open('w') as xerr:
            xserver = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0',
                                       '800x600x24', '-nolisten', 'tcp'],
                                      stdout=subprocess.PIPE, stderr=xerr,
                                      text=True, start_new_session=True)
            import select
            if not select.select([xserver.stdout], [], [], 5)[0]:
                raise RuntimeError('X server did not allocate a display')
            env['DISPLAY'] = ':' + xserver.stdout.readline().strip()
        with log.open('w') as stdout, (output / 'stderr.log').open('w') as stderr:
            app = subprocess.Popen([str(binary)], env=env, stdout=stdout,
                                   stderr=stderr, start_new_session=True)
            window = None
            while time.monotonic() < deadline:
                result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name',
                                         '^NeLisp GTK4 OS probe$'], env=env,
                                        capture_output=True, text=True, timeout=2)
                if result.returncode == 0 and result.stdout.strip():
                    window = result.stdout.splitlines()[0]
                    break
                if app.poll() is not None:
                    raise RuntimeError(f'Probe exited before window: {app.returncode}')
                time.sleep(.05)
            if not window:
                raise RuntimeError('GTK window did not appear')
            run(['xdotool', 'windowfocus', '--sync', window], env)

            def key(value):
                run(['xdotool', 'key', '--clearmodifiers', value], env)

            def expect(value):
                nonlocal consumed
                end = min(deadline, time.monotonic() + 2)
                while time.monotonic() < end:
                    match = log.read_text(encoding='utf-8').find(value, consumed)
                    if match >= 0:
                        consumed = match + len(value)
                        checks.append(value)
                        return
                    if app.poll() is not None:
                        break
                    time.sleep(.03)
                raise RuntimeError(f'Native widget readback missing: {value}')

            key('a')
            expect('PREEDIT: a\n')
            key('shift+b')
            expect('PREEDIT: aB\n')
            key('ctrl+c')
            time.sleep(.1)
            if log.read_text().splitlines()[-1] != 'PREEDIT: aB':
                raise RuntimeError('Control modifier changed preedit')
            checks.append('Control modifier ignored')
            key('U304b')
            expect('PREEDIT: aB\u304b\n')
            key('U6f22')
            expect('PREEDIT: aB\u304b\u6f22\n')
            run(['xwd', '-silent', '-id', window, '-out',
                 str(output / 'preedit.xwd')], env)
            run(['convert', str(output / 'preedit.xwd'),
                 str(output / 'preedit.png')], env)
            key('BackSpace')
            expect('PREEDIT: aB\u304b\n')
            key('Return')
            expect('COMMIT: aB\u304b\nPREEDIT: \n')
            key('U65e5')
            expect('PREEDIT: \u65e5\n')
            run(['xwd', '-silent', '-id', window, '-out',
                 str(output / 'commit.xwd')], env)
            run(['convert', str(output / 'commit.xwd'),
                 str(output / 'commit.png')], env)
            if close_request:
                request_close(env['DISPLAY'], window)
            else:
                key('Escape')
            exit_code = app.wait(timeout=3)
            if exit_code:
                raise RuntimeError(f'Probe exit: {exit_code}')
            checks.append('GTK close request exits successfully' if close_request
                          else 'Escape exits successfully')
        if negative:
            raise RuntimeError('Disabled callback unexpectedly passed')
        return {'status': 'PASS', 'checks': checks, 'binary_sha256':
                hashlib.sha256(binary.read_bytes()).hexdigest()}
    except Exception as error:
        if negative and str(error).startswith('Native widget readback missing:'):
            return {'status': 'EXPECTED_FAILURE', 'reason': str(error), 'checks': checks}
        raise
    finally:
        stop(app)
        stop(xserver)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--negative', action='store_true')
    parser.add_argument('--close-request', action='store_true')
    args = parser.parse_args()
    result = verify(args.binary.resolve(), args.output.resolve(), args.negative,
                    args.close_request)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))
