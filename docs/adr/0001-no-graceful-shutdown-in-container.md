# No graceful shutdown in containers

A containerized `server serve` does not shut its Nebula child down gracefully: the
process has no SIGTERM handler, so `defer nebulaProcess.Stop()` never runs. We accept
that rather than change the Go source, because containerization is not evidence that the
program cannot start — and the map scopes out source changes unless a ticket proves one
is required. `exec` is still used, so the Go process is PID 1 and no shell swallows the
signal — but **the exit code is not part of the contract**, and acceptance must not assert
`143` (see "2026-10-27 correction: exit code 143 does not hold" below).

## Status

accepted

## Considered Options

- **exec the binary as PID 1** — chosen. Costs nothing, removes the shell from the
  signal path, and leaves the failure mode honest.
- **signal proxy (tini / an entrypoint loop that forwards SIGTERM)** — rejected. Forwarding
  lands in the same place: the program still has no handler, so the deferred child stop
  still never runs. It buys nothing for a dependency to trust.
- **add `signal.Notify` + explicit Nebula stop to the Go source** — deferred, not rejected.
  It is the only path to a genuinely graceful stop, and it is a change to the product, not
  to the packaging. It belongs to its own ticket if anyone wants it.

## Consequences

- "Clean exit" for acceptance means three checkable things, not a nebula shutdown log:
  `docker stop` returns within the grace period, the Lighthouse identity (CA
  fingerprint, paired devices) survives a restart, and `server-state.json` plus
  `history.sqlite` are intact afterwards.
- A future reader who wonders why the image does not use tini finds the reason here.

## 2026-10-27 correction: exit code 143 does not hold

The earlier text claimed the stop exits `143`. Two verified mechanisms defeat that, so acceptance
now asserts three observable things instead: the stop completes inside the grace period,
Lighthouse identity survives a restart, and the state file plus history database are intact.

1. **The process never sees SIGTERM.** The kernel marks the init process of a PID namespace
   `SIGNAL_UNKILLABLE` (`kernel/fork.c`, set when `is_child_reaper(pid)`; `kernel/signal.c`
   drops namespace-local signals to it in both `sig_task_ignored()` and the default-action
   branch). A plain `docker stop` sends SIGTERM from the same namespace, so it is never
   delivered to the Go process; SIGKILL after the grace period is what ends the container.
2. **Even if delivered, Go would not exit 143.** The Go runtime lists SIGTERM as
   `_SigNotify + _SigKill` (`runtime/sigtab_linux_generic.go`). With no `os/signal.Notify`,
   `sigfwdgo` forwards to the default handler and calls `dieFromSignal`, whose fallback
   is `exit(2)`.

Consequences: **do not** assert `143`, and **do not** assert `137` either. If a real run reports
137, the reading is "the grace period was too short", not "the product is broken". These
namespace-init semantics could not be exercised in the build sandbox (no `/dev/fuse`,
`unshare -Ur` refused), so this rests on kernel source, not experiment.

## Unverified fallback: root → chown → setpriv

If acceptance shows the named volume's copy-up layer is not owned by 10001, the entrypoint
falls back to `root → chown the state root → setpriv → exec the server`. The "no signal
proxy, service is PID 1" decision still stands, because the exec'd process is still the
server; only the privilege drop moves earlier. This path is untested — enable it only if
acceptance proves it is needed.
