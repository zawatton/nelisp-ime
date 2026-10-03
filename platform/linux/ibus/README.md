# IBus adapter

The bridge exposes the shared NeLisp engine through IBus with live preedit,
native lookup-table candidates, per-context sessions, and JSON learning under
`$XDG_DATA_HOME/nelisp-ime`.

Run `make -C platform/linux/ibus check`, then install using the Makefile and
restart the IBus daemon. Development builds may set `NELISP_IME_RUNTIME` and
`NELISP_IME_ROOT`.

## Engine startup

The engine process starts NeLisp on a worker thread, so IBus creates and
selects the engine immediately. Until NeLisp is ready, each engine holds up to
64 key presses (the romaji is shown as preedit), then replays them in order;
keys the engine does not consume are forwarded to the application. Further
keys during startup are dropped and logged as `QUEUE_FULL`. If NeLisp fails to
start, held keys are forwarded unchanged and the engine passes keys through.

## Desktop verification

`make -C platform/linux/ibus desktop-check` registers the component from this
source tree with a private `ibus-daemon`, then types into a GTK4 entry with
xdotool and checks the committed text. It requires Xvfb, xdotool,
`dbus-daemon`, `ibus-daemon`, and PyGObject with the IBus 1.0 and GTK 4
typelibs. The harness uses isolated XDG directories and an in-memory GSettings
backend, and reaps every process it starts. Modes are `control` (engine not
selected; text arrives unconverted), `convert`, `burst` (one 1 ms-delay xdotool
call), and `early` (keys typed while a deliberately slowed NeLisp is starting).
Evidence and per-process logs, including `engine.log`, remain under
`build/desktop/`.
