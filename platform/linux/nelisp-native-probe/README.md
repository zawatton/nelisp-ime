# NeLisp native GTK4 OS probe

This proof routes GTK4 `GtkEventControllerKey::key-pressed` events into a NeLisp AOT callback. The callback decodes keyvals with `gdk_keyval_to_unicode`, encodes complete UTF-8 code points with `g_unichar_to_utf8`, updates native GTK labels, and reads the displayed text back for `PREEDIT:` and `COMMIT:` traces. Backspace removes one complete UTF-8 code point. Return commits the current preedit and Escape, window close, or a 30-second timer quits the loop.

This validates OS keyboard events reaching NeLisp-compiled GTK callback code. It does not connect to Fcitx, IBus, TSF, or a conversion engine, and it does not perform romaji-to-kanji conversion.

Compile from the probe directory using GNU Emacs to load the repository's AOT compiler sources:

```sh
emacs -Q --batch -l build-probe.el -- native-probe.el
gcc build/native-probe.o $(pkg-config --cflags --libs gtk4) -o build/native-probe
```

Set `NELISP_ROOT` when the NeLisp checkout is not at `../../../../nelisp`, `NELISP_PROBE_OUT_DIR` to select another isolated output directory, or `NELISP_PROBE_OBJECT` to select an exact object path. The compiler driver uses a private overlay containing symlinks to only the repository's `.el` sources; it preserves Emacs' normal system load suffixes. Run under a display or isolated Xvfb session. Inject key events with an OS-level tool such as `xdotool`; assert the widget-derived trace, including a Japanese character, Backspace, commit, and preedit clear.

Callback ABI: `key-pressed` receives `(controller, keyval, keycode, state, user_data)` and returns GTK `gboolean`; `close-request` receives `(window, user_data)`. User data points to a 1600-byte allocation: loop at offset 0, committed label at 8, preedit label at 16, timeout source id at 24, 512-byte UTF-8 preedit at 32, and temporary UTF-8 codepoint at 544. Control, Alt, Super, Hyper, and Meta modified text keys pass through; Shift remains available for ordinary text. The GTK main loop owns callback lifetime until quit, then removes the timeout and destroys the GTK objects before freeing context.

Run the retained integration check on Linux (requires GTK4 development libraries, GNU Emacs, GCC, Xvfb, xdotool, xwd and ImageMagick):

```sh
sh verify.sh
```

The runner uses an owned Xvfb display, reads actual GTK label state after ASCII and Japanese key events, captures preedit/commit screenshots, and checks a successfully built disabled-callback negative control. Artifacts are retained under `build/verification/`. It bounds subprocesses and terminates only its own process groups. The proof covers x86-64 Linux GTK callbacks, not installation as a system-wide IME.
