#!/bin/bash
# Site DC router (dc-muc, dc-vie). LAB PROTOTYPE.
# - eBGP (unnumbered) to the internet node, as the gateways do.
# - Bridges lb, b1, b2, m1, m2 into br0 = the site DC LAN (NET.65/28).
# - Route health injection: the anycast broker.lab (198.51.100.100) points to
#   the site haproxy while it is healthy, and mqtt.lab (198.51.100.101) to
#   the healthy EMQX nodes of the site (ECMP). BGP announces what is there.
# - On the gateway VPN ("vpn", like ov.ffmuc.net in production) it announces
#   only mqtt.lab to the gateways. So a worker reaches MQTT also when the
#   uplink of its gateway is cut.
# The uplink is "wan": "up" is a keyword of the ip command.
# Env: ASN, NET (first three octets), BASE (last octet of the /28), VPN_ADDR.
set -eu
ifs="wan lb b1 b2 m1 m2 vpn"
for i in ${ifs}; do
	while ! ip link show "${i}" >/dev/null 2>&1; do sleep 1; done
done
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv6.conf.all.disable_ipv6=0
sysctl -q -w net.ipv6.conf.all.forwarding=1
sysctl -q -w net.ipv6.conf.wan.disable_ipv6=0
ip link add br0 type bridge
for i in lb b1 b2 m1 m2; do
	ip link set "${i}" master br0 up
done
ip link set br0 up
ip link set wan up
ip link set vpn up
ip addr add "${VPN_ADDR}/24" dev vpn
ip addr add "${NET}.$((BASE + 1))/28" dev br0
lb="${NET}.$((BASE + 2))"
m1="${NET}.$((BASE + 5))"
m2="${NET}.$((BASE + 6))"

cat > /etc/frr/frr.conf <<CONF
ip prefix-list dc seq 5 permit 198.51.100.0/24 le 32
ip prefix-list mqtt seq 5 permit 198.51.100.101/32
route-map dc permit 10
  match ip address prefix-list dc
route-map mqtt permit 10
  match ip address prefix-list mqtt
route-map none deny 10
!
router bgp ${ASN}
  bgp router-id ${NET}.$((BASE + 1))
  no bgp ebgp-requires-policy
  no bgp default ipv4-unicast
  neighbor wan interface v6only remote-as external
  neighbor GW peer-group
  neighbor GW remote-as external
$(for i in 1 2 3 4; do echo "  neighbor 172.16.0.${i} peer-group GW"; done)
  address-family ipv4 unicast
    redistribute connected route-map dc
    redistribute kernel route-map dc
    neighbor wan activate
    neighbor GW activate
    neighbor GW route-map none in
    neighbor GW route-map mqtt out
  exit-address-family
!
CONF

# Like the haproxy "fall 3 rise 1" checks: a target goes down after 3 failed
# checks in a row, and up after 1 good check. One slow answer does not
# withdraw the route.
fails_dir=/run/rhi
mkdir -p "${fails_dir}"
up() {
	f="${fails_dir}/$(echo "$1" | tr -c 'a-zA-Z0-9' _)"
	if wget -q -T 2 -O /dev/null "$1" 2>/dev/null; then
		echo 0 > "${f}"
		return 0
	fi
	n=$(( $(cat "${f}" 2>/dev/null || echo 3) + 1 ))
	echo "${n}" > "${f}"
	[ "${n}" -lt 3 ]
}
rhi() {
	while true; do
		if up "http://${lb}/haproxy-health"; then
			ip route replace 198.51.100.100/32 via "${lb}"
		else
			ip route del 198.51.100.100/32 2>/dev/null || true
		fi
		hops=""
		for m in "${m1}" "${m2}"; do
			up "http://${m}:18083/api/v5/status" && hops="${hops} nexthop via ${m}"
		done
		if [ -n "${hops}" ]; then
			# shellcheck disable=SC2086 # one word per nexthop part
			ip route replace 198.51.100.101/32 ${hops}
		else
			ip route del 198.51.100.101/32 2>/dev/null || true
		fi
		sleep 1
	done
}
rhi &
exec /usr/lib/frr/docker-start
