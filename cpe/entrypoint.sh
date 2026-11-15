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
# This is the resolver the APs get handed over DHCP, and the broker hands them
# concentrator endpoints by name (endpoint_name in the wgkex config), so the
# gateway names have to resolve here. The addresses are the gateways' public
# IPv4, see host_vars/parker-gw0*/vars in gateway/packer/ffbs-ansible.
# broker.lab is the anycast address of the two haproxies (multipop/lb).
# --local=/lab/ makes this dnsmasq authoritative for the names below, so a query
# for one it has no record of (an AAAA, say) is answered right away instead of
# being forwarded to an upstream this container does not have.
exec dnsmasq -i lan -k -F 192.168.10.100,192.168.10.199,6h \
	--local=/lab/ \
	--host-record=gw1.lab,198.51.100.1 \
	--host-record=gw2.lab,198.51.100.2 \
	--host-record=gw3.lab,192.0.2.3 \
	--host-record=gw4.lab,192.0.2.4 \
	--host-record=broker.lab,203.0.113.250 # -F ::,constructor:lan,slaac
