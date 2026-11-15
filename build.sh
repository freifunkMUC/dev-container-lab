#!/usr/bin/env bash

set -eEu

cd "$(dirname "$0")"

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

pushd gateway/packer
./build.sh
popd

# Resize on the host: a resize in the Dockerfile stores the image twice.
for gw in parker-gw01 parker-gw02 parker-gw03 parker-gw04; do
	qemu-img resize "gateway/${gw}.qcow2" "${GATEWAY_DISK_SIZE:-10G}"
	docker build --build-arg IMAGE="${gw}.qcow2" gateway -t "ffmuc-lab:gateway-${gw}"
done

docker build toolbox -t ffmuc-lab:toolbox
