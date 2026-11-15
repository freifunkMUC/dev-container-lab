#!/bin/bash

until [ -e /sys/class/net/lan ]; do sleep 1; done

echo LAN online

# Multi-PoP: the node sends one router advertisement with the prefixes of
# both sites. IPV6_CLIENT=dhcpcd lets dhcpcd do the IPv6 autoconfig (it
# keeps a list of prefixes for each router); else the kernel does it.
if [ "${IPV6_CLIENT:-kernel}" = dhcpcd ]; then
	sysctl -q -w net.ipv6.conf.lan.accept_ra=0
	dhcpcd -t 0 -w lan
else
	sysctl -q -w net.ipv6.conf.lan.accept_ra=2
	sysctl -q -w net.ipv6.conf.lan.autoconf=1
	dhcpcd -4 -t 0 -w lan
fi

exec sleep infinity
