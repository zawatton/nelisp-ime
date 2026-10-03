# Fcitx 5 adapter

This addon maps every Fcitx input context to a NeLisp protocol session. It
uses romaji input, client preedit, the native candidate panel, and one resident
standalone NeLisp process.

```sh
cmake -S platform/linux/fcitx5 -B platform/linux/fcitx5/build
cmake --build platform/linux/fcitx5/build
cmake --install platform/linux/fcitx5/build
```

For a development checkout, set `NELISP_IME_RUNTIME` and `NELISP_IME_ROOT`.

The addon starts and recovers the NeLisp process on a worker thread. Fcitx
callbacks never wait for cold startup. While startup or recovery runs,
unmodified key presses are held per input context (up to 64, shown as
underlined preedit; further keys are dropped and logged as `QUEUE_FULL`). When
NeLisp becomes ready they are replayed in order, and keys the engine does not
consume are forwarded to the application. If startup fails, held keys are
forwarded unchanged; a context reset discards them and deactivating the input
method forwards them. The key whose request hit a transport failure is still
passed through, and the next callback lazily reopens its context session after
recovery. Transport failures clear every live context. Protocol errors discard only the
affected local session and leave the client connection available. Learning
load failures keep conversion unavailable and preserve the learning file for
the next retry.

To build and run the native callback fixture against an installed Fcitx 5 SDK:

```sh
cmake -S platform/linux/fcitx5 -B platform/linux/fcitx5/build -DNELISP_IME_BUILD_TESTS=ON
cmake --build platform/linux/fcitx5/build
ctest --test-dir platform/linux/fcitx5/build --output-on-failure
```

## Desktop verification

`verify-desktop-suite.py BUILD_DIR OUTPUT` loads the addon from a build
directory into a private `fcitx5` (own Xvfb, session D-Bus and isolated XDG
directories), types into a GTK4 entry with xdotool and checks the committed
text. Modes are `control` (input method inactive), `convert`, `burst`, `early`
(keys typed while a slowed NeLisp starts; nothing may leak and the held keys
must convert), and `recover` (the NeLisp runtime is killed and the same fcitx5
process converts again). It needs Xvfb, xdotool, `dbus-daemon`, fcitx5 with
its GTK 4 frontend, and PyGObject with GTK 4. Set `FCITX5_PREFIX` to use an
installation other than `/usr`, for example one unpacked with `dpkg -x`.

```sh
NELISP_IME_RUNTIME=target/nelisp python3 platform/linux/fcitx5/verify-desktop-suite.py \
  platform/linux/fcitx5/build platform/linux/fcitx5/build/desktop
```
