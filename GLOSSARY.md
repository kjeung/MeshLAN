# MeshLAN

MeshLAN is a self-hosted mesh VPN control plane: it hands out Nebula identities and
keeps a roster of devices and nodes on one machine the operator controls.

## Language

**Lighthouse**:
A MeshLAN anchor that is always reachable at a public endpoint; devices and nodes learn
every other peer's address from it.
_Avoid_: seed node, hub, bootstrap server

**Node**:
A second Lighthouse registered into another Lighthouse's network: it shares that
network's CA and device roster but is reachable at its own public endpoint.
_Avoid_: agent, worker, child server, relay

**Relay**:
A capability a Lighthouse may carry — it forwards traffic between two peers that cannot
punch through to each other directly. It is not a role.
_Avoid_: proxy, middlebox, third role

**Pairing**:
The one-time exchange that binds a device or a node to a Lighthouse, ending with it
holding a certificate for the mesh.
_Avoid_: enrollment secret, invite, join token

**State root**:
The directory a running Lighthouse or Node keeps its identity and history in.
_Avoid_: data dir, volume, home directory

**Entrypoint contract**:
The agreed shape of how a container decides what to run, which ports it opens, and how
it reports health.
_Avoid_: boot script, launcher, wrapper
