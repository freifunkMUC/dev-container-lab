#!/usr/bin/env bash

set -eEu

cd "$(dirname "$0")"

# The gluon image builds the patched uradvd; its build context is gluon/.
cp multipop/patches/uradvd.patch gluon/uradvd.patch
docker build --build-arg IMAGE=gluon-ffmuc-*-x86-64*.img gluon -t ffmuc-lab:gluon

# The gateways install wgkex from a source tree, so Ansible needs a copy of it
# at gateway/packer/wgkex-src (wgkex_src_dir in ffbs-ansible). It comes from the
# wgkex submodule; point WGKEX_SRC at a checkout of your own to build a
# different revision.
WGKEX_SRC="${WGKEX_SRC:-gateway/packer/wgkex}"
if [ ! -e "${WGKEX_SRC}/wgkex/broker/app.py" ]; then
	echo "No wgkex source at ${WGKEX_SRC}." >&2
	echo "Run 'git submodule update --init', or set WGKEX_SRC to your own." >&2
	exit 1
fi
if [ -d gateway/packer/wgkex-src ]; then
	rm -r gateway/packer/wgkex-src
fi
mkdir -p gateway/packer/wgkex-src
tar -C "${WGKEX_SRC}" --exclude=.git --exclude=bazel-\* -cf - . \
	| tar -C gateway/packer/wgkex-src -xf -
# Multi-PoP active/standby lab: per-site prefixes and primary_site in the
# broker answer. LAB PROTOTYPE, see gateway/packer/multipop/.
patch -d gateway/packer/wgkex-src -p1 < gateway/packer/multipop/wgkex-multipop.patch

# Broker plane (multipop/brokers/): the stateless brokers run the same
# patched source, and EMQX gets "ip" for the lab address setup.
docker build -f multipop/brokers/Dockerfile gateway/packer/wgkex-src -t ffmuc-lab:broker
docker build -f multipop/brokers/Dockerfile.emqx multipop/brokers -t ffmuc-lab:emqx

pushd gateway/packer
./build.sh
popd

# One gateway image for all four. Each gateway disk stays in gateway/ and
# ffmuc.clab.yml binds it into the container (read-only), so the disks are
# never copied into an image or the build cache. Keep gateway/*.qcow2 while
# the lab runs. The resize changes only the virtual size.
for gw in parker-gw01 parker-gw02 parker-gw03 parker-gw04; do
	qemu-img resize "gateway/${gw}.qcow2" "${GATEWAY_DISK_SIZE:-10G}"
done
docker build gateway -t ffmuc-lab:gateway

docker build toolbox -t ffmuc-lab:toolbox
