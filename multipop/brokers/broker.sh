#!/bin/sh
# wgkex broker: write its config, then run it. Env: MQTT (its EMQX node).
set -eu
key=$(sed -n 2p /sec/lab-node-config.sec)
sed -e "s|@MQTT@|${MQTT}|" -e "s|@SIGNING_KEY@|${key}|" /lab/wgkex.yaml > /tmp/wgkex.yaml
# The broker exits if MQTT is down at start. EMQX starts slowly, so wait.
until python -c "import socket; socket.create_connection(('${MQTT}', 1883), 2)" 2>/dev/null; do
	sleep 2
done
exec python -m wgkex.broker.app
