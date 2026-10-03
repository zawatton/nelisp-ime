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
callbacks never wait for cold startup; while recovery runs, new keys pass
through and the next callback lazily opens its context session after recovery.
Transport failures clear every live context. Protocol errors discard only the
affected local session and leave the client connection available. Learning
load failures keep conversion unavailable and preserve the learning file for
the next retry.

To build and run the native callback fixture against an installed Fcitx 5 SDK:

```sh
cmake -S platform/linux/fcitx5 -B platform/linux/fcitx5/build -DNELISP_IME_BUILD_TESTS=ON
cmake --build platform/linux/fcitx5/build
ctest --test-dir platform/linux/fcitx5/build --output-on-failure
```
