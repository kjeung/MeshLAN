# Tun device names are clamped to the kernel limit

Every nebula config renderer names its tun device through `tunDeviceName`, which
clamps the name to 15 bytes (`IFNAMSIZ` 16 minus the terminating NUL). The Lighthouse
uses `meshlan-lh`; the Node keeps `MeshLAN-Node`; the Windows client keeps `MeshLAN`.

## Status

accepted

## Context

`server serve` rendered `tun.dev: MeshLAN-Lighthouse`, 18 bytes. nebula copies that into
a 16-byte `ifreq.ifr_name` before `TUNSETIFF` without NUL-terminating it, and the kernel
rejects a full 16-byte name in two places: `dev_valid_name`
(`strnlen(name, IFNAMSIZ) == IFNAMSIZ`) and `alloc_netdev_mqs`
(`BUG_ON(strlen(name) >= sizeof(dev->name))`). The Lighthouse therefore died at startup on
every Linux host, container or not — see [Fix the Lighthouse tun device name so it can
start on Linux](https://github.com/kjeung/MeshLAN/issues/9).

`nebula -test` cannot catch this: `configTest` skips the entire tun creation block, so a
build-time smoke test passes on a config that cannot start.

## Considered Options

- **shorten the Lighthouse name and clamp every renderer** — chosen. The kernel counts
  bytes, so the clamp does too, and no renderer can reintroduce the bug.
- **shorten only the Lighthouse name** — rejected. It fixes today's offender but leaves the
  same trap for any future name.
- **make `tun.dev` operator-configurable** — rejected for now. It adds an input to verify
  (and a new way to write an over-long name) to buy flexibility nobody asked for. A
  per-host clash between two MeshLAN instances still needs an answer; that is a separate
  ticket, and it can revisit this constant.

## Consequences

- Existing state roots need no migration: `server serve` rewrites `lighthouse.yml` on every
  start, so a restarted Lighthouse picks up `meshlan-lh` where an old file said
  `MeshLAN-Lighthouse`. A device created under the old name is left behind on the host;
  it is inert, and the new name wins at the next start.
- The regression guard is a Go test (`cmd/meshlan/tun_device_name_test.go`), because
  `nebula -test` stays blind to the condition. Adding a renderer means going through
  `tunDeviceName` and adding it to that test's role table.
- Two MeshLAN instances on one host share `meshlan-lh`. Documented, not solved here.