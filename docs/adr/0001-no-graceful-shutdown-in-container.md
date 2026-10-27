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

## Fallback is now the fixed path: root → chown → setpriv

**Measured 2026-10-27 on a real Docker host** (Debian 12, Docker 29.8.1): a freshly created
named volume mounts with owner `0:0` and 0755, and uid 10001 cannot write into it
(`Permission denied`). After `chown 10001:10001` and `chmod 700`, uid 10001 writes and
creates subdirectories normally. So the entrypoint **always** runs

`root → chown the state root → setpriv → exec the server`,

not just when acceptance proves it is needed. The "no signal proxy, service is PID 1"
decision still stands, because the exec'd process is still the server; only the privilege
drop moves earlier. The same probe confirmed the TUN side: nebula needs an explicit
`/dev/net/tun` device node (self-creating it requires `CAP_MKNOD`, which the minimal capability
set lacks), and a non-root run needs `NET_ADMIN` in the bounding set **plus** a file capability
on the binary — either one alone fails. See the owning spec for the full capability matrix.
## 2026-10-27 measured: the real build and run

The predictions above now have their first real measurements, from a Debian 12 host
(Docker 29.8.1, kernel 6.1.0-9-amd64) with `/dev/net/tun`.

**Exit code.** `docker compose stop` against the running Lighthouse exited **2**, which is the
`dieFromSignal` fallback the correction above predicted, not 143 and not 137. Across nine
stops the exit code was 2 every time. The stop itself returned in **449 / 590 / 728 ms** against
a 30 s grace period, so it is not the SIGKILL-after-timeout path.

**Identity.** The CA fingerprint (`httpsCaFingerprint`) was byte-identical before and after a
restart and after a full `up -d --force-recreate`, and `server-state.json`,
`history.sqlite` (+ WAL) and `first-credentials.txt` (0600) all survived. The Node role kept
its `id` across a restart too.

**Nothing to add about the signal path itself** — the decision not to install a signal proxy
stands, and "clean exit" still means the three checkable things listed under Consequences, not a
graceful Nebula shutdown log.

## 2026-10-27 measured: capabilities must be stamped last

A build container's bounding set does not include NET_ADMIN (measured:
`CapBnd=00000000a80425fb`). So once a binary carries `cap_net_admin=ep`, executing it *inside*
the RUN step fails with `Operation not permitted` (exit 126) — the capability is granted for the
container run, which gets NET_ADMIN from compose, not for the build.

`nebula -version` therefore has to run **before** `setcap`, which is the order the Dockerfile now
uses. This is packaging order, not a change to the product: the in-image smoke checks still run
against the shipped bytes, and `getcap` afterwards proves both stamps landed.

Related, and also measured: `setcap cap_net_admin+ep <a> <b>` fails on the **second** file with
`fatal error: Invalid argument` under libcap 2.75 on this kernel, while each one-file call
succeeds — it is not atomic, so `<a>` is already stamped when the command returns non-zero. Both
the Dockerfile and `docker/entrypoint.sh` now call `setcap` once per file.
