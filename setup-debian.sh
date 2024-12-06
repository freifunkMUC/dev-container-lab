#!/bin/bash

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

# download ffmuc parker firmware from https://github.com/freifunkMUC/site-ffm/commits/parker/
wget -O x86-64.zip "$link zu x86-64.zip von der CI aus https://github.com/freifunkMUC/site-ffm/commits/parker/"
unzip x86-64.zip
gunzip --keep ./images/factory/gluon-ffmuc-v2024.9.1-next-26-g7bc48a0~run11637604636-x86-64.img.gz

# clone ffmuc-lab
git clone https://github.com/lukasstockner/ffmuc-lab.git
cd ffmuc-lab
cp ../images/factory/gluon-ffmuc-v2024.9.1-next-26-g7bc48a0~run11637604636-x86-64.img gluon/

# create network
sudo ip link add ap-1-lan type bridge
sudo ip link add ap-2-lan type bridge
sudo ip link add gateway-vpn type bridge
sudo ip link set ap-1-lan up
sudo ip link set ap-2-lan up
sudo ip link set gateway-vpn up

# clone gateway setup ansible into packer folder
git clone -C gateway/packer -b lab-setup https://github.com/lukasstockner/ffbs-ansible/tree

sudo apt install qemu-system wireguard sshpass
sudo usermod -aG libvirt ffac

# sudo apt install ansible # https://github.com/ansible/ansible/issues/83213#issuecomment-2101029891 - ansible needs python 3.12 support
sudo apt install pipx signify-openbsd

pipx install --include-deps ansible
ansible-galaxy collection install ansible.posix

packer plugins install github.com/hashicorp/ansible
packer plugins install github.com/hashicorp/qemu

pushd gateway/packer
echo "mypassword" > ffbs-ansible/.vault
./node-config-keygen.sh
./etcd-ca/openssl-ca.sh
echo "TODO copy output of ./wireguard-keygen.sh"
echo "TODO into host_vars/*"
popd

./build.sh

sudo containerlab deploy
