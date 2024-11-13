#!/bin/bash

packer init gateway.pkr.hcl

packer build -var hostname=parker-gw01 gateway.pkr.hcl &
packer build -var hostname=parker-gw02 gateway.pkr.hcl &
packer build -var hostname=parker-gw03 gateway.pkr.hcl &
packer build -var hostname=parker-gw04 gateway.pkr.hcl &
wait

# Packer breaks the console state somehow, so fix it
reset

mv output-*/*.qcow2 ..
rm -r output-*
