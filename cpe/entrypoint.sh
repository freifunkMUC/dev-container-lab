#!/bin/bash
set -e

until [ -e /sys/class/net/lan ]; do sleep 1; done
until [ -e /sys/class/net/wan ]; do sleep 1; done

sysctl -w net.ipv4.ip_forward=1

ip addr add $WAN_IP4 dev wan
ip route add default via $WAN_GW4

#ip addr add $WAN_IP6 dev wan
#ip -6 route add default via $WAN_GW6

ip addr add 192.168.10.1/24 dev lan
#ip addr add $LAN_IP6 dev lan

# The multitool image ships neither iptables nor nft by default -- the
# original iptables MASQUERADE failed silently for the lab's whole life.
# nftables comes from the toolbox Dockerfile.
nft add table ip nat
nft 'add chain ip nat postrouting { type nat hook postrouting priority srcnat; }'
nft add rule ip nat postrouting oifname "wan" masquerade
exec dnsmasq -i lan -k -F 192.168.10.100,192.168.10.199,6h # -F ::,constructor:lan,slaac
