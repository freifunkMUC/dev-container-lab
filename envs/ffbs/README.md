# Environment "ffbs"

The Parker setup of Freifunk Braunschweig (FFBS), as upstream has it:

- 3 concentrators and 1 exit (Debian 12 VMs).
- etcd on the concentrators. It keeps the node configuration.
- A WireGuard backbone between the concentrators and the exit, with OSPF.
- The exit sends the client traffic through a WireGuard tunnel to the
  `internet` node.
- 2 homes: each has a CPE, an AP with the stock FFBS firmware, and clients.

The upstream Ansible ([ffbs-ansible](https://gitli.stratum0.org/ffbs/ffbs-ansible))
is the submodule `ffbs-ansible`. The build does not change it. It copies it to
`gateway/packer/ffbs-stage` and puts the lab files of `lab/` into the copy:

| File | Purpose |
| --- | --- |
| `lab/inventory` | The lab hosts. The playbook skips the plays with the tag `with_prod`. |
| `lab/group_vars`, `lab/host_vars` | Lab addresses and lab keys. |
| `lab/files` | The build makes the signify key of the node configuration and the etcd certificates here (not in git). |
| `lab/lab-pre.yml` | Runs before the playbook: host name, Debian stable only, packages. |
| `lab/lab-post.yml` | Runs after the playbook: lab network, etcd start on first boot. |
| `lab/keygen.sh` | Makes new lab keys. The build runs `keygen.sh signify` and `keygen.sh etcd` when the files are missing. |

The keys in `lab/` are lab keys. They are public. Do not use them outside the
lab.

## Use

```sh
git submodule update --init
# Put the x86-64 FFBS Gluon image into gluon/, e.g. gluon-ffbs-<version>-x86-64.img
./lab.sh -e ffbs build
./lab.sh -e ffbs deploy
./lab.sh -e ffbs test
./lab.sh -e ffbs destroy
```

`./lab.sh -e ffbs cmd concentrator1 'sudo wg show'` runs a command on a VM.
The gateway login is `debian` / `ffmuc`.

## Addresses

| Network | Addresses |
| --- | --- |
| WAN (`fb-wan`) | concentrator1-3: 198.51.100.1-3, exit1: 198.51.100.11, internet: 198.51.100.254, 2001:db8:100::/64 |
| Backbone | 172.16.1.1-3 (concentrators), 172.16.2.1 (exit1) |
| Exit tunnel | 100.64.0.1-2/30, 2001:db8:ff::/64 |
| Gateway management | 192.0.2.0/24 (the FFBS routes use 10.0.0.0/8 and 172.16.0.0/12) |
| Homes | CPE WAN 203.0.113.1/30 and 203.0.113.5/30 |
| Test targets | 203.0.113.42, 2001:db8:cafe::1 |

## Differences to production

- Lab keys, lab addresses, no admin users, no prod tags (monitoring, web).
- Debian stable packages only. Upstream also adds testing and unstable.
- `exit1` uses the `internet` node as its VPN provider.
- The config server is concentrator1 (`CONFIGSERVER` in `ffbs.clab.yml`).
