#!/usr/bin/env bash

set -eEu

cd "$(dirname "$0")"

# Multi-PoP: per-site changes to the gateway submodules.
./multipop/apply-patches.sh

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

docker build --build-arg IMAGE=parker-gw01.qcow2 gateway -t ffmuc-lab:gateway-parker-gw01
docker build --build-arg IMAGE=parker-gw02.qcow2 gateway -t ffmuc-lab:gateway-parker-gw02
docker build --build-arg IMAGE=parker-gw03.qcow2 gateway -t ffmuc-lab:gateway-parker-gw03
docker build --build-arg IMAGE=parker-gw04.qcow2 gateway -t ffmuc-lab:gateway-parker-gw04

docker build toolbox -t ffmuc-lab:toolbox
