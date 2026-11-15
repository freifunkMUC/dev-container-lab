#!/bin/sh
# LAB: one load balancer. haproxy runs below service.sh, so the tests can
# kill it. A watchdog keeps the anycast address on lo only while haproxy
# answers, so the internet router stops sending traffic here when it fails.
set -eu
ANYCAST=203.0.113.250/32

sysctl -q -w net.ipv4.ip_forward=0

(
	while :; do
		if [ ! -e /tmp/down ] && curl -s -o /dev/null -m 1 http://127.0.0.1/haproxy-alive; then
			ip addr replace "${ANYCAST}" dev lo
		else
			ip addr del "${ANYCAST}" dev lo 2>/dev/null || true
		fi
		sleep 0.3
	done
) &

/svc/service.sh haproxy -W -db -f /etc/haproxy/haproxy.cfg &

until ip -4 addr show eth1 | grep -q inet; do sleep 0.2; done
exec /usr/lib/frr/docker-start
