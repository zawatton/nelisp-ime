# Common IME client IPC

`Client::TimeoutPolicy` sets independent startup and response deadlines. Both
default to a positive duration (60 seconds for startup, 10 seconds per response)
and apply to the complete newline-terminated protocol line using a monotonic
clock; trickled bytes do not extend the deadline. EOF, timeout, or a pipe error
closes the connection and terminates/reaps the child. Windows cleanup allows up
to 100 ms for exit before force termination; POSIX sends SIGTERM, waits up to
200 ms, then sends SIGKILL and reaps. Applications recover with `start()` and
reopen their sessions. Protocol-level error replies leave the transport usable.

The request write remains synchronous, so an unusually large write can still
block on a full pipe. Routine fault checks use `cmake --build <build-dir>` and
`ctest --test-dir <build-dir> --output-on-failure`; the fault test has an 8-second
outer timeout. `make fault-smoke` is also available on POSIX hosts with `timeout`.
