#!/usr/bin/env bash
# Create the host bridges the topology attaches to, and let traffic bridged
# between lab nodes through the host firewall. Wants root, is idempotent, and
# has to run again after a reboot.
#
# docker loads br_netfilter with bridge-nf-call-iptables=1, so every frame
# bridged between two lab nodes also traverses the host's iptables chains.
# There it meets docker's FORWARD policy of DROP, and on a host whose firewall
# does strict reverse-path filtering in mangle PREROUTING it is dropped there
# as well, since the host has no routes to the lab subnets. ARP is not IP and
# passes both, so the lab deploys and resolves addresses while not one packet
# gets through.

set -eu

bridges="as-ap1-lan as-ap2-lan as-ap3-lan as-ap4-lan as-home1 as-home2 as-gw-vpn"

if [ "$(id -u)" != 0 ]; then
	echo "needs root: sudo $0" >&2
	exit 1
fi

for br in ${bridges}; do
	ip link show "${br}" >/dev/null 2>&1 || ip link add "${br}" type bridge
	ip link set "${br}" up
	# Keep the host's own IPv6 stack off the bridges, so what a client sees
	# there comes from the lab and from nowhere else.
	sysctl -q -w "net.ipv6.conf.${br}.disable_ipv6=1"
done

for tool in iptables ip6tables; do
	command -v "${tool}" >/dev/null || continue
	# DOCKER-USER is consulted before docker's own rules and never flushed.
	"${tool}" -N DOCKER-USER 2>/dev/null || true
	# The reverse-path filter sits in a chain of the firewall's own naming,
	# if the firewall has one at all.
	rpfilter=$("${tool}" -t mangle -S PREROUTING 2>/dev/null |
		sed -n 's/.*-j \([A-Za-z0-9_.-]*rpfilter[A-Za-z0-9_.-]*\).*/\1/p' |
		head -1)
	for br in ${bridges}; do
		"${tool}" -C DOCKER-USER -i "${br}" -o "${br}" -j ACCEPT 2>/dev/null ||
			"${tool}" -I DOCKER-USER 1 -i "${br}" -o "${br}" -j ACCEPT
		[ -n "${rpfilter}" ] || continue
		"${tool}" -t mangle -C "${rpfilter}" -i "${br}" -j RETURN 2>/dev/null ||
			"${tool}" -t mangle -I "${rpfilter}" 1 -i "${br}" -j RETURN
	done
done
