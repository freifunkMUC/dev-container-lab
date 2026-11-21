#!/bin/bash

until [ -e /sys/class/net/lan ]; do sleep 1; done

echo LAN online

# Multi-PoP active/standby lab: the node sends one RA with the prefixes of
# both sites. IPV6_CLIENT=dhcpcd lets dhcpcd do the IPv6 autoconfig; else
# the kernel does SLAAC and dhcpcd does only IPv4.
sysctl -w net.ipv6.conf.lan.disable_ipv6=0
sysctl -w net.ipv6.conf.lan.use_tempaddr=0
if [ "${IPV6_CLIENT:-kernel}" = dhcpcd ]; then
	sysctl -w net.ipv6.conf.lan.accept_ra=0
	dhcpcd -t 0 -w lan
else
	sysctl -w net.ipv6.conf.lan.accept_ra=2
	sysctl -w net.ipv6.conf.lan.autoconf=1
	dhcpcd -4 -t 0 -w lan
fi

exec sleep infinity
