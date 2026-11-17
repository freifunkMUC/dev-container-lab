#!/usr/bin/env bash

packer init gateway.pkr.hcl

pids=()
for gw in parker-gw01 parker-gw02 parker-gw03 parker-gw04; do
  packer build ${PACKER_ARGS:-} -var hostname=$gw gateway.pkr.hcl &
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

mv output-*/*.qcow2 ..
rm -r output-*
