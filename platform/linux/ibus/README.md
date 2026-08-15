# IBus adapter

The bridge exposes the shared NeLisp engine through IBus with live preedit,
native lookup-table candidates, per-context sessions, and JSON learning under
`$XDG_DATA_HOME/nelisp-ime`.

Run `make -C platform/linux/ibus check`, then install using the Makefile and
restart the IBus daemon. Development builds may set `NELISP_IME_RUNTIME` and
`NELISP_IME_ROOT`.
