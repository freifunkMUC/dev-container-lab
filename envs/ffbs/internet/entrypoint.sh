#!/bin/sh
# The internet of the ffbs environment. Static routes only, no BGP:
#   wan    198.51.100.254/24, 2001:db8:100::254/64: concentrators and exit1
#   cpe1   203.0.113.2/30  (home 1)
#   cpe2   203.0.113.6/30  (home 2)
#   wg-exit 100.64.0.1/30, 2001:db8:ff::1/64: the exit tunnel of exit1
#   lo     203.0.113.42, 2001:db8:cafe::1: the test targets
set -e

for i in wan cpe1 cpe2; do
	until [ -e "/sys/class/net/$i" ]; do sleep 1; done
done

sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv6.conf.all.forwarding=1
sysctl -qw net.ipv6.conf.all.accept_ra=0

ip addr add 203.0.113.42/32 dev lo
ip -6 addr add 2001:db8:cafe::1/128 dev lo
ip addr add 198.51.100.254/24 dev wan
ip -6 addr add 2001:db8:100::254/64 dev wan nodad
ip addr add 203.0.113.2/30 dev cpe1
ip addr add 203.0.113.6/30 dev cpe2

# Lab keys, see envs/ffbs/lab/keygen.sh. They are not secret.
echo 'cBml8gJzGYfMv1yHBB+9f0FoSLYHNCM17Q3wtbMRc2w=' > /tmp/wg.key
ip link add wg-exit type wireguard
wg set wg-exit listen-port 51820 private-key /tmp/wg.key \
	peer '7kyfZ+GucTN2BUebTFQwawjpHNicVadQwMwJqxI/zho=' \
	allowed-ips 100.64.0.2/32,2001:db8:ff::2/128
ip addr add 100.64.0.1/30 dev wg-exit
ip -6 addr add 2001:db8:ff::1/64 dev wg-exit nodad
ip link set wg-exit up

exec sleep infinity
