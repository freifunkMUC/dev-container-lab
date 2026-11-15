#!/bin/bash

until [ -e /sys/class/net/lan ]; do sleep 1; done

echo LAN online

# Multi-PoP active/standby lab: the kernel does SLAAC, dhcpcd does only IPv4.
# The lab AP sends one RA per site prefix (one uradvd per site). dhcpcd marks
# a prefix that is missing from an RA of the same router as stale and
# deprecates it, so the two RAs would deprecate each other. The kernel
# handles each prefix on its own. Real firmware needs one uradvd that sends
# both prefixes with their own lifetimes.
sysctl -w net.ipv6.conf.lan.disable_ipv6=0
sysctl -w net.ipv6.conf.lan.accept_ra=2
sysctl -w net.ipv6.conf.lan.autoconf=1
sysctl -w net.ipv6.conf.lan.use_tempaddr=0

dhcpcd -4 -t 0 -w lan

exec sleep infinity
