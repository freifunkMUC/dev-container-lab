#!/bin/sh
# LAB: one EMQX node. All nodes of both sites form one cluster with static
# seeds, as in production (stacks/docker0*/wgkex/compose.yaml in
# ffmuc-salt-public). The node name is the address, so it needs no DNS.
set -eu
ip=${ADDR%/*}
export EMQX_NODE__NAME="emqx@${ip}"
export EMQX_NODE__COOKIE=ffmuc-lab-cookie
export EMQX_CLUSTER__DISCOVERY_STRATEGY=static
export EMQX_CLUSTER__STATIC__SEEDS="${SEEDS}"
# Find a dead peer fast (the default is minutes).
export EMQX_NODE__DIST_NET_TICKTIME=8
exec /svc/service.sh runuser -u emqx -- /usr/bin/docker-entrypoint.sh /opt/emqx/bin/emqx foreground
