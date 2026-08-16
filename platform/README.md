# NeLisp IME platform adapters

All adapters are clients of `packages/nelisp-ime` protocol version 1. They must
keep one engine process resident, assign a unique session ID to each native
input context, and send normalized events. Conversion policy and learning must
not be reimplemented in platform code.

| Platform | Native API | Adapter status |
|---|---|---|
| macOS | InputMethodKit | Buildable app, candidate UI, bundled dictionary, learning persistence |
| Linux | Fcitx 5 | Native addon, preedit/candidates, learning, integrated installer |
| Linux | IBus | Python/GObject bridge, lookup table, learning, integrated installer |
| Windows | Text Services Framework | Provided by [nelisp-skk-ime](https://github.com/zawatton/nelisp-skk-ime) -- see below |

The OS boundary intentionally uses JSON-compatible values so native adapters
can be developed and tested independently from the Elisp conversion engine.
The common C++ client is compiled on POSIX and Windows and has an integration
smoke covering romaji input, phrase conversion, candidate selection, commit,
and learning reload.

## Windows

This repository no longer ships a TSF text service.  The Windows stack lives
in nelisp-skk-ime, which is in daily production use and is the hardened half
of the system: it multiplexes the engine pipe, fails open to the application
when the engine is unavailable, resynchronizes after an IPC timeout, drives
garbage collection from idle, and keeps the dictionary in the host process.

The adapter that used to live here started the engine synchronously from
`ITfTextInputProcessor::Activate`, which blocked the calling application's UI
thread for the length of a cold engine start -- seconds, in a callback that
every text-input app runs.  Rather than reimplement what the other stack
already got right, this framework speaks that stack's wire format:
`packages/nelisp-ime/src/nelisp-ime-stateline.el` answers the same STATE line
protocol, so the shipped host and text service can drive this engine
unmodified and select between engines with the `ENGINE` verbs.
