# NeLisp GTK native IME bridge: engine process

This directory's engine entry loads the same six source files used by the shared native client, opens a `romaji` session through protocol version 1, and prints `READY` after initialization. Each subsequent REPL form calls `native-ime-request` with an operation (`key`, `commit`, `cancel`, or `select-candidate`) and an ASCII key string, producing one JSON-RPC response line. Conversion, candidates, and commit data come from the actual NeLisp engine and bundled dictionary. The GTK demonstration displays the currently selected candidate; Space advances the selection.

Set `NELISP_IME_RUNTIME` to the standalone NeLisp executable. `NELISP_IME_ROOT` defaults to the repository root inferred from the launcher; `NELISP_IME_ENTRY` can select another entry file. Build and run the GTK app with:

```sh
NELISP_IME_RUNTIME=/path/to/nelisp sh ./run.sh
```

This is a standalone GTK demonstration, not an installed system IME. The GTK host owns the engine process, bounds startup and request waits, permits only one request in flight, and terminates the child during teardown. It must not retry a timed-out operation because IME input is stateful.

For a direct real-engine check, launch the runtime with `--repl --no-prompt --no-print`, then send `(load (getenv "NELISP_IME_ENTRY"))` on stdin. After `READY`, send one REPL form per line, for example `(native-ime-request "key" "k")` and `(native-ime-request "key" "a")`. Runtime startup/engine initialization still requires the actual standalone runtime and data; this entry does not provide a fallback romanizer or dictionary.

## Build and verification

The Linux x86-64 host is compiled from raw NeLisp forms with the sibling probe's source-only AOT driver. GTK4, GLib/GIO and JSON-GLib provide their existing C ABIs; there is no authored C/C++ adapter. Build dependencies are Emacs, GCC and the development packages for GTK4 and JSON-GLib. `NELISP_ROOT` selects the compiler checkout and defaults to the sibling `nelisp` directory. The engine sources are selected separately by `NELISP_IME_ROOT`.

Run the repeatable suite with Xvfb, xdotool and ImageMagick installed:

```sh
NELISP_IME_RUNTIME=/path/to/nelisp \
  python3 verify-suite.py . ./build/verification
```

The suite checks the entire source structure and four deliberately broken inputs before building once. It then uses real GTK key events and widget getter traces to verify `kanji` -> `漢字`, Space -> `幹事`, Enter commit, next input and Backspace. Ctrl/Alt keys and Space without candidates pass through. A burst mode sends `kanji`, Space and Enter in one 1 ms-delay xdotool call to the real engine and requires the `幹事` commit. A queue-overflow mode holds the first request in a fault process, types 80 keys, and requires the first 65 keys to be processed in order with exactly 15 `QUEUE_FULL` traces. Screenshots and JSON evidence remain in the output directory.

Fault processes are used only for negative cases: hung startup, hung response, protocol error, malformed JSON, a wrong result type and closed stdin. Escape must work during startup and a pending response. Every case checks that the owned engine was reaped and rejects GTK/GLib critical warnings. A separate control changes only the real engine entry's key operation to cancel; initialization must succeed and the expected conversion must be absent.

Startup defaults to 60 seconds and responses to 500 milliseconds, configurable through `NELISP_IME_STARTUP_TIMEOUT_MS` and `NELISP_IME_RESPONSE_TIMEOUT_MS` (1..60000). Keys pass through while the engine is starting. Once it is ready, letters, Backspace, Enter and Space that arrive while a request is pending, or while earlier keys are still queued, are consumed and queued in arrival order. Up to 64 keys can be queued in addition to the one in flight. Each response sends the next queued key, and a queued Space selects the next candidate using the candidate count at the time the key is sent. If no candidates are available at that time, the Space is dropped. Keys that arrive while the queue is full are consumed, dropped and traced as `QUEUE_FULL`. Ctrl/Alt/Super combinations always pass through and are not ordered with queued keys. An engine failure ends the session and discards the queue. Timed-out operations are never retried. This demonstration does not provide a desktop input-method registration or Fcitx/IBus/TSF installation.

The structural guard enforces explicit single-body forms and rejects boxed strings passed to C APIs. It is a conservative source convention, not proof of compiler semantics. The suite also compares its rejection time with a full AOT/link rejection of the same boxed-string control; a focused measurement was 0.0637 seconds versus 0.1967 seconds. Full core bootstrap and unrelated broad gates are deliberately excluded because the engine sources and compiler core are unchanged.

Validation records the exact compiler and engine revisions separately. This slice initially used compiler sources `77b4dee490c9f828babd3df69456e4e184d9389c` with the existing Linux runtime from `ec25865506ebfb8582022d49bbe2ab502d3b82e8`; it does not imply that the Linux runtime was rebuilt from the newer compiler sources.
