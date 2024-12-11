#!/bin/bash

set -eEu

cd "$(dirname "$0")"

docker build --build-arg IMAGE=gluon-ffmuc-*-x86-64*.img gluon -t ffmuc-lab:gluon

pushd gateway/packer
./build.sh
popd

docker build --build-arg IMAGE=parker-gw01.qcow2 gateway -t ffmuc-lab:gateway-parker-gw01
docker build --build-arg IMAGE=parker-gw02.qcow2 gateway -t ffmuc-lab:gateway-parker-gw02
docker build --build-arg IMAGE=parker-gw03.qcow2 gateway -t ffmuc-lab:gateway-parker-gw03
docker build --build-arg IMAGE=parker-gw04.qcow2 gateway -t ffmuc-lab:gateway-parker-gw04

docker build toolbox -t ffmuc-lab:toolbox
