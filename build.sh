#!/usr/bin/env bash
# Build the images of one lab environment.
# Usage: ./build.sh [ENV]   (default: LAB_ENV, else ffmuc; see envs/)

set -eEu

cd "$(dirname "$0")"
# shellcheck source=lib/env.sh
. lib/env.sh
load_env "${1:-}"
echo "build.sh: environment ${ENV_NAME}"

# The AP image. The gluon image builds the uradvd prototype; its build
# context is gluon/. Without a patch, the uradvd is built unpatched.
image=$(fetch_gluon)
if [ -n "${GLUON_URADVD_PATCH}" ]; then
	cp "${GLUON_URADVD_PATCH}" gluon/uradvd.patch
else
	: > gluon/uradvd.patch
fi
docker build --build-arg IMAGE="${image}" gluon -t "${IMAGE_PREFIX}:gluon"

env_prepare

GATEWAYS="${GATEWAYS}" PACKER_VARS="${PACKER_VARS}" OUTPUT_DIR="$(pwd)/${GATEWAY_DIR}" \
	bash -c 'cd gateway/packer && ./build.sh'

# One gateway image for all gateways. Each gateway disk stays in
# GATEWAY_DIR and the topology binds it into the container (read-only), so
# the disks are never copied into an image or the build cache. Keep the
# disks while the lab runs. The resize changes only the virtual size.
for gw in ${GATEWAYS}; do
	qemu-img resize "${GATEWAY_DIR}/${gw}.qcow2" "${GATEWAY_DISK_SIZE:-10G}"
done
docker build gateway -t "${IMAGE_PREFIX}:gateway"

docker build toolbox -t "${IMAGE_PREFIX}:toolbox"

env_build_extra
