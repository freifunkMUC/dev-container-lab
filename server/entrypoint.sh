#!/bin/bash
# Multi-PoP test server. Echoes the source address of each TCP connection on
# port 8080, so a test can see which prefix or NAT64 address a client used.

until [ -e /sys/class/net/eth1 ]; do sleep 1; done

ip addr add 203.0.113.66/30 dev eth1
ip route add default via 203.0.113.65
ip addr add 2001:db8:cafe:1::2/64 dev eth1 nodad
ip -6 route add default via 2001:db8:cafe:1::1

reply='printf "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n%s\n" "$SOCAT_PEERADDR"'
socat TCP4-LISTEN:8080,fork,reuseaddr SYSTEM:"$reply" &
socat TCP6-LISTEN:8080,ipv6only=1,fork,reuseaddr SYSTEM:"$reply" &

exec sleep infinity
