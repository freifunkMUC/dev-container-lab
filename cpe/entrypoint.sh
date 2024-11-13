#!/bin/bash

until [ -e /sys/class/net/lan ]; do sleep 1; done
until [ -e /sys/class/net/wan ]; do sleep 1; done

ip addr add $WAN_IP4 dev wan
ip route add default via $WAN_GW4

#ip addr add $WAN_IP6 dev wan
#ip -6 route add default via $WAN_GW6

ip addr add 192.168.10.1/24 dev lan
#ip addr add $LAN_IP6 dev lan

iptables -t nat -A POSTROUTING -o wan -j MASQUERADE
exec dnsmasq -i lan -k -F 192.168.10.100,192.168.10.199,6h # -F ::,constructor:lan,slaac
