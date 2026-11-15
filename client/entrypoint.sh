#!/bin/bash

until [ -e /sys/class/net/lan ]; do sleep 1; done

echo LAN online

# Multi-PoP: the node sends one router advertisement per site. The kernel
# keeps the lifetimes of each prefix apart, so it does the IPv6 autoconfig
# here, and dhcpcd does only IPv4.
sysctl -q -w net.ipv6.conf.lan.accept_ra=2
sysctl -q -w net.ipv6.conf.lan.autoconf=1

dhcpcd -4 -t 0 -w lan

exec sleep infinity
