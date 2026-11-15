#!/bin/sh
# LAB: one stateless wgkex broker. MQTT is the EMQX node next to it (MQTT),
# as in production. The signing key comes from the lab key file, which
# containerlab mounts at /run/node-config.sec.
set -eu
sed "s/@MQTT@/${MQTT}/" /etc/wgkex/wgkex.yaml >/run/wgkex.yaml
printf "broker_signing_key: '%s'\n" "$(sed -n 2p /run/node-config.sec)" >>/run/wgkex.yaml
exec /svc/service.sh python -m wgkex.broker.app
