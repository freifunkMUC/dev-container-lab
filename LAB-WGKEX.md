# The lab on wgkex

The gateways used to run [etcd-tools](https://github.com/freifunkMUC/etcd-tools)
(`etcdconfigweb` and `concentratorconfig`) on top of an etcd cluster. They now
run [wgkex](https://github.com/freifunkMUC/wgkex), which is what FFMUC runs in
production, so the lab exercises the code that actually serves the network.

## What replaced what

| Before | Now |
| --- | --- |
| etcd cluster on all four gateways | none, wgkex keeps its state in MQTT and a JSON file |
| `etcdconfigweb` on all four gateways | one wgkex broker, on gw01 |
| `concentratorconfig` on all four gateways | a wgkex worker on every gateway |
| etcd TLS certificates from `etcd-ca/openssl-ca.sh` | none |
| Ansible Vault for the WireGuard and signing keys | plain lab keys in the repository |

Unchanged: the `wg-nodes` interface itself (systemd-networkd, port 10000), the
lab network (FRR, nftables, systemd-networkd), nginx, and Jool.

The broker and the worker are two systemd units, `wgkex-broker.service` and
`wgkex-worker.service`, running out of a virtualenv in `/opt/wgkex`. They share
`/etc/wgkex.yaml`. `build.sh` copies the `gateway/packer/wgkex` submodule to
`gateway/packer/wgkex-src` and Ansible installs it from there, so a change in
wgkex reaches the lab by rebuilding the gateway images. Point `WGKEX_SRC` at a
checkout of your own to build a revision the submodule is not pinned to.

The two of them meet on a mosquitto instance on gw01, reachable over the
gateway VPN with no authentication - the firewall only lets the gateways onto
that bridge. Workers announce their endpoint, public key and peer count there;
the broker hands nodes the peers to build and the workers create them.

## Addresses

The broker allocates a /63 per node out of `2001:db8:ff00::/48`, skipping the
first one, and splits it into the /64 the node's clients live in (`range6`) and
the /64 it translates their IPv4 into (`xlat_range6`). The first two APs to ask
therefore end up with:

| | AP that asks first | AP that asks second |
| --- | --- | --- |
| `range6` | `2001:db8:ff00:2::/64` | `2001:db8:ff00:4::/64` |
| `xlat_range6` | `2001:db8:ff00:3::/64` | `2001:db8:ff00:5::/64` |
| `address6` | `2001:db8:ff00:2::1` | `2001:db8:ff00:4::1` |

The allocations live in `/var/local/wgkex/broker/ipv6_ranges.json` on gw01 and
survive a broker restart, but not a rebuild of the image.

Every node is given the same `range4`, `10.0.4.0/22`, and the same `address4`,
`10.0.4.1`. That is what Parker does: with 464XLAT the client IPv4 never leaves
the node, so all of them can use the same range.

## Concentrator selection

The four gateways are split into two PoPs, `pop-a` (gw01, gw02) and `pop-b`
(gw03, gw04). wgkex hands every node one concentrator per PoP, so each AP
builds two tunnels, `wg_c<id>`, and `noderoute` picks its default route from
whichever of them has a live handshake. Taking a gateway down should move a
node to the other one in its PoP within a config retry (120s) plus the
WireGuard handshake timeout (180s).

The concentrator IDs are static, from `wgkex_worker_id` in the host_vars: gw01
is 1 and gw04 is 4. They name the interfaces on the node, so they must not be
renumbered.

## Trusting the lab broker

The AP image is built with FFMUC's production `parker.config_pubkey` in
site.conf, which the lab has no secret key for. `906-parker-nodeconfig` seeds
that key into `parker.nodeconfig.config_pubkey`, and `nodeconfig.sh` reads it
from there rather than from site.conf, so the lab overrides the uci value over
the serial console with the key in
`gateway/packer/ffbs-ansible/files/lab-node-config.pub` (`CONFIGPUBKEY` in
`ffmuc.clab.yml`). The broker signs with the matching `.sec`.

`906-parker-nodeconfig` rewrites both `config_server` and `config_pubkey` from
site.conf on every run of the upgrade scripts, so `launch.py` runs
`gluon-reconfigure` itself and only then writes the two overrides. Running
`gluon-reconfigure` on a node by hand puts the production values back and the
node stops accepting configurations until they are set again.

## Bringing it up

Same as before, apart from a second submodule.

No `.vault` file is needed anymore. `./build.sh` installs wgkex from the
`gateway/packer/wgkex` submodule unless `WGKEX_SRC` says otherwise.

## Checking it

On gw01:

```
systemctl status wgkex-broker wgkex-worker mosquitto
journalctl -u wgkex-broker -f
mosquitto_sub -h 172.16.0.1 -t '#' -v          # every worker should appear
cat /var/local/wgkex/broker/ipv6_ranges.json   # one /63 per AP
curl 'http://127.0.0.1:5000/config?pubkey=<node pubkey>&nonce=x&v6mtu=1500'
```

On any gateway: `wg show wg-nodes` lists one peer per AP with the node's /63 as
its allowed-ips, and `ip -6 route show dev wg-nodes` the matching routes.

On an AP: `logread -f -e nodeconfig` shows the fetch and the signature check.
`Signature validation failed` means the `config_pubkey` override is not in
place.

### What is different from the etcd-tools bring-up

CLAT is now always active, because wgkex only implements 464XLAT. On an AP that
means:

- `wg show` reports `allowed ips: ::/0` on both tunnels, and no IPv4 ones.
- The client network gets a PREF64 option in its router advertisements and
  DHCPv6 option 108 telling clients IPv4 is unnecessary.
- DHCP option 26 is 28 bytes below the router advertisement MTU, and the MSS
  clamp on IPv4 is 28 bytes lower than on IPv6 (see the MTU table in
  `ffbs-mesh-vpn-parker/README.md`).
- `ip link show clat` exists and carries the client traffic.

The gateways no longer NAT44: the nftables `ip nat` rule for `wg-nodes` cannot
match anymore, because `wg-nodes` has no IPv4 address (see below) and no IPv4
reaches it. Client IPv4 arrives translated and leaves through Jool.

## Two things worth knowing

`wg-nodes` is IPv6-only on purpose. The worker publishes the first address the
kernel reports for the interface as the address nodes should use for their end
of the tunnel, and the kernel reports IPv4 first. With an IPv4 address on
`wg-nodes` the nodes would be told to configure `10.0.0.x` as an IPv6 peer
address, which fails.

The broker hardcodes `10.0.0.1` as the concentrator's `address4` for every
concentrator (`wgkex/broker/app.py`, marked TODO). A node with two tunnels can
only install that peer route once, so the second tunnel logs a failed
`ip -4 addr add` on every config cycle. It is noise: no IPv4 travels through
the tunnels.
