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
| Windows | Text Services Framework | Buildable per-user COM DLL, composition, learning, installer |

The OS boundary intentionally uses JSON-compatible values so native adapters
can be developed and tested independently from the Elisp conversion engine.
The common C++ client is compiled on POSIX and Windows and has an integration
smoke covering romaji input, phrase conversion, candidate selection, commit,
and learning reload.

The TSF target additionally has a Windows-ABI smoke that loads the DLL,
resolves its COM class factory, creates `ITfTextInputProcessor`, and exercises
registration/unregistration.  The dedicated CI workflow repeats this on a
native Windows runner.
