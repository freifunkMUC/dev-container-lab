#!/bin/bash
# One-time host setup for the lab on a Debian-based machine.
# Read it before running it: several steps want sudo, and the firmware
# download needs a browser session for the GitHub artifact link.

set -eu

# install docker
wget https://gist.githubusercontent.com/maurerle/276fead798430a0ab3d59b86b0d6b494/raw/6616bf7c23e50bc8f12beb036198005dde943d9d/docker-install.sh
chmod +x docker-install.sh
sudo ./docker-install.sh
sudo apt install unzip

# install containerlab
# https://containerlab.dev/install/#quick-setup
curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"

# install packer
# https://developer.hashicorp.com/packer/install#linux
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install packer

# Download the x86-64 output of a parker-branch CI run from
# https://github.com/freifunkMUC/site-ffm/actions?query=branch%3Aparker
# (artifact "x86-64_output"), then extract the factory image into gluon/:
#   unzip x86-64_output.zip
#   gunzip --keep images/factory/gluon-ffmuc-<version>-x86-64.img.gz
#   cp images/factory/gluon-ffmuc-<version>-x86-64.img gluon/
# build.sh expects exactly one gluon/*.img.

# create the host bridges the topology attaches to, and let traffic bridged
# between lab nodes through the host firewall (the script says why)
sudo ./lab-bridges.sh

sudo apt install qemu-system qemu-utils wireguard sshpass pipx signify-openbsd

pipx install --include-deps ansible
ansible-galaxy collection install ansible.posix

packer plugins install github.com/hashicorp/ansible
packer plugins install github.com/hashicorp/qemu

# ffbs-ansible ships ready-made lab credentials (WireGuard keys in host_vars,
# a signify pair in files/) -- throwaway keys that secure nothing outside this
# lab. Regenerate them with node-config-keygen.sh and wireguard-keygen.sh in
# gateway/packer if you want your own. wgkex is the source tree the gateways
# install from.
git submodule update --init

./build.sh

sudo containerlab deploy
