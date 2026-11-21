#!/usr/bin/env bash
# Build the gateway disks with Packer, one VM per gateway, in parallel.
# GATEWAYS: the gateway names (the inventory host names).
# PACKER_VARS: a Packer variable file of the environment (optional).
# OUTPUT_DIR: where the disks go, NAME.qcow2.

GATEWAYS="${GATEWAYS:-parker-gw01 parker-gw02 parker-gw03 parker-gw04}"
OUTPUT_DIR="${OUTPUT_DIR:-..}"
var_file=()
[ -n "${PACKER_VARS:-}" ] && var_file=(-var-file "${PACKER_VARS}")

packer init gateway.pkr.hcl

pids=()
for gw in ${GATEWAYS}; do
  # shellcheck disable=SC2086
  packer build ${PACKER_ARGS:-} "${var_file[@]}" -var hostname="$gw" gateway.pkr.hcl &
  pids+=($!)
done
rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || rc=1
done

# Packer breaks the console state somehow, so fix it
reset || true

if [ "$rc" -ne 0 ]; then
  echo "build.sh: a packer build failed" >&2
  exit 1
fi

for gw in ${GATEWAYS}; do
  mv "output-${gw}/${gw}.qcow2" "${OUTPUT_DIR}/"
  rm -r "output-${gw}"
done
