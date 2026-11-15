#!/bin/sh
# Entrypoint of the broker plane containers (lb-*, broker-*, emqx-*).
# Sets the lab address on eth1, the default route to the site DC router and
# an optional anycast address on lo, then runs the service ("$@").
# Env: ADDR (a.b.c.d/28), GW, ANYCAST (optional /32).
set -eu
while ! ip link show eth1 >/dev/null 2>&1; do sleep 1; done
ip link set eth1 up
ip addr add "${ADDR}" dev eth1
ip route replace default via "${GW}"
if [ -n "${ANYCAST:-}" ]; then
	ip addr add "${ANYCAST}/32" dev lo
fi
# The one name of the MQTT cluster, as broker.ov.ffmuc.net in production.
echo "198.51.100.101 mqtt.lab" >> /etc/hosts
if [ -n "${RUN_AS:-}" ]; then
	# shellcheck disable=SC2016 # $0 and $@ expand in the inner shell
	exec su -s /bin/sh -c 'exec "$0" "$@"' "${RUN_AS}" -- "$@"
fi
exec "$@"
