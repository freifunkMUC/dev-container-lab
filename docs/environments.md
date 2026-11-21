# Lab environments

An environment is one lab setup: the topology, the gateway build, the Gluon
image and the tests. Each environment is a directory `envs/NAME/` with an
`env.conf` file.

| Environment | Setup |
| --- | --- |
| `ffmuc` (default) | FFMUC multi-PoP active/standby: 2 sites, wgkex brokers, DNS64 and NAT64. Refer to [MULTIPOP-AS.md](../MULTIPOP-AS.md). |
| `ffbs` | FFBS Parker as upstream: etcd, concentrators, exit, stock FFBS firmware. Refer to [envs/ffbs/README.md](../envs/ffbs/README.md). |
| `example` | Template: the ffbs setup with your own Gluon image. |

## Commands

`./lab.sh` is the entry point. Select the environment with `-e NAME` or
`LAB_ENV=NAME`. Without them, the environment is `ffmuc`.

```sh
./lab.sh list                 # show the environments
./lab.sh -e ffbs info         # show the settings
./lab.sh -e ffbs build        # build the images (same as ./build.sh ffbs)
./lab.sh -e ffbs deploy       # make the host bridges, start the lab
./lab.sh -e ffbs test         # run the tests of the environment
./lab.sh -e ffbs cmd ap-1 'wg show all'
./lab.sh -e ffbs destroy
./lab.sh -e ffbs run          # build, deploy, test, collect logs, destroy
```

The old commands still work for `ffmuc`: `./build.sh`, `sudo ./lab-bridges.sh`,
`sudo containerlab deploy -t ffmuc.clab.yml`, `./run.sh`.

## env.conf

`env.conf` is a bash file. `lib/env.sh` loads it. Paths are relative to the
repository root.

| Variable | Meaning |
| --- | --- |
| `LAB_NAME` | The `name:` in the topology. Container names are `clab-LAB_NAME-NODE`. |
| `TOPOLOGY` | The containerlab topology file. |
| `IMAGE_PREFIX` | Docker image tags: `IMAGE_PREFIX:gluon`, `:gateway`, `:toolbox`. Use a different prefix for each environment. |
| `BRIDGES` | Host bridges of the topology. `lab-bridges.sh` makes them. |
| `GATEWAYS` | Gateway VM names. Packer builds one disk per name: `gateway/NAME.qcow2`. |
| `GATEWAY_NODES` | containerlab nodes of the gateways (for logs). |
| `GATEWAY_USER`, `GATEWAY_PASS` | Serial console login of the gateways. |
| `PACKER_VARS` | Packer variable file, relative to `gateway/packer/`. Empty: the ffmuc gateways. |
| `APS` | containerlab nodes of the APs (for logs). |
| `GLUON_IMAGE` | The Gluon image: a file name glob in `gluon/`, a path, or an https URL (`.img` or `.img.gz`). |
| `GLUON_URADVD_PATCH` | Optional patch for the uradvd prototype in the AP image. |

Hooks (bash functions, all optional):

| Hook | When |
| --- | --- |
| `env_prepare` | Before the gateway build. Copy sources, make keys. |
| `env_deploy_vars` | Before the deploy. Prints `VAR=VALUE` lines for the topology (for example a generated key). |
| `env_build_extra` | After the gateway build. Build more images. |
| `env_tests` | `./lab.sh test` and `./run.sh`. Gets `--results DIR`. |
| `env_collect_logs` | `./run.sh`, after the tests. Gets the log directory. |

## Gateway provisioning

Each environment selects how its gateways are built. `gateway/packer/gateway.pkr.hcl`
boots a cloud image and runs three Ansible playbooks: `pre_playbook`,
`playbook` and `overlay_playbook`. The `PACKER_VARS` file sets them, and the
base image, login, inventory and Ansible arguments. Packer runs in
`gateway/packer/`, so the paths in the file are relative to it.

- `ffmuc`: Ubuntu, the ffbs-ansible fork (`gateway/packer/ffbs-ansible`) and
  `multipop/overlay.yml`. These are the defaults of `gateway.pkr.hcl`.
- `ffbs`: Debian 12 and the upstream ffbs-ansible (`envs/ffbs/gateway.pkrvars.hcl`).
  `env_prepare` makes a copy with the lab inventory.

To use other provisioning (another Ansible repository, or a script that you
call from a playbook), write a new variable file. Use `gateway/packer/noop.yml`
for a playbook that you do not need. To use the provisioning in your own
network, add it as a git submodule below `envs/NAME/` and stage it in
`env_prepare`, as `envs/ffbs/env.conf` does.

## Custom Gluon image or patches

The lab does not build Gluon. Build your firmware with your site and your
patches (x86-64 target), then give the image to the lab:

```sh
GLUON_IMAGE_URL=https://example.org/gluon-mysite-1.0-x86-64.img.gz ./lab.sh -e example build
# or put the file into gluon/ and set GLUON_IMAGE in env.conf
```

For small changes without a new firmware, the AP container can change the
node at the first boot, before `gluon-reconfigure`. Set these in the
topology, at the AP node:

| Setting | Effect |
| --- | --- |
| `binds: [path/ap-files:/ap-files:ro]` | Copies each text file below `ap-files/` to the same path on the node. |
| `env: AP_SETUP` | Shell commands, one per line, run on the node. |
| `env: AP_SETUP_FILE` | A file in the container with shell commands, one per line. Bind it in. |
| `env: LAB_FIRMWARE: old` | Do not add the ffmuc prototype. Use this for each firmware other than ffmuc. |
| `env: CONFIGSERVER`, `CONFIGPUBKEY` | The config server and the key of the lab. |

## Add an environment

1. Copy `envs/example` to `envs/NAME`.
2. In `env.conf`, set what is different. To use a new topology, copy
   `envs/ffbs/ffbs.clab.yml`. Change `name:`, the management subnet, the
   bridge names and the image prefix, so that it can run next to the other
   environments.
3. Run `./lab.sh -e NAME info` to check the settings.
4. Run `./lab.sh -e NAME build`, `deploy` and `test`.
