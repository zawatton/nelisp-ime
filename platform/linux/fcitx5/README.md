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
