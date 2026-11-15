#!/usr/bin/env bash

set -eEu

cd "$(dirname "$0")"

# Multi-PoP: per-site changes to the gateway submodules.
./multipop/apply-patches.sh
# The gluon image builds the patched uradvd; its build context is gluon/.
cp multipop/patches/uradvd.patch gluon/multipop/uradvd.patch

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

pushd gateway/packer
./build.sh
popd

# One gateway image for all four. The topology mounts gateway/parker-gwNN.qcow2
# into it (read-only), so no disk is copied into an image or the build cache.
for gw in gw01 gw02 gw03 gw04; do
	qemu-img resize "gateway/parker-${gw}.qcow2" 10G
done
docker build gateway -t ffmuc-lab:gateway

docker build toolbox -t ffmuc-lab:toolbox

# Multi-PoP: the control plane, as in production (see MULTIPOP.md). The broker
# image uses the same patched wgkex tree as the gateways.
docker build --build-context wgkex=gateway/packer/wgkex-src multipop/broker -t ffmuc-lab:broker
docker build multipop/emqx -t ffmuc-lab:emqx
docker build multipop/lb -t ffmuc-lab:lb
