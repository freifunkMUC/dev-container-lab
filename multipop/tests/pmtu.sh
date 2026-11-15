#!/usr/bin/env bash
# Path MTU per site. A packet of the tunnel MTU with the source of a site
# must arrive. A packet that is 1 byte larger must not, and the client must
# learn the smaller MTU (ICMPv6 packet too big is not rejected). IPv4 goes
# through the CLAT, which adds 20 bytes.
. "$(dirname "$0")/common.sh"

declare -A MTU MTU4
for ap in ${APS}; do
	for site in muc01 vie01; do
		ifc=$(site_ifc "$ap" "$site")
		MTU[${ap}_${site}]=$(node "$ap" "cat /sys/class/net/${ifc}/mtu" | tr -d '\r')
	done
	MTU4[${ap}]=$(node "$ap" "ip -4 route show default" | grep -oE 'mtu [0-9]+' | cut -d' ' -f2)
	log "$ap MTU: muc01 ${MTU[${ap}_muc01]}, vie01 ${MTU[${ap}_vie01]}, IPv4 route ${MTU4[${ap}]:-none}"
done
ap_of() { case "$1" in client-1 | client-2) echo ap-1 ;; *) echo ap-2 ;; esac; }

for c in ${CLIENTS}; do
	ap=$(ap_of "$c")
	for p in "A muc01 ${PREFIX_A}" "B vie01 ${PREFIX_B}"; do
		set -- $p
		src=$(addr_in "$c" "$3")
		m=${MTU[${ap}_$2]}
		[ -n "$m" ] || { check "$c site $1 MTU" fail "no MTU for $ap $2"; continue; }
		# 48 bytes: the IPv6 header and the ICMPv6 echo header.
		out=$(dx "$c" ping -6 -c 3 -i 0.5 -W 2 -M "do" -s $((m - 48)) -I "$src" "${SERVER6}" 2>&1)
		echo "$out" | grep -qE ' [123] received' &&
			check "$c site $1: $m byte packets arrive" ok "$(echo "$out" | grep received)" ||
			check "$c site $1: $m byte packets arrive" fail "$(echo "$out" | tail -n 2 | tr '\n' ';')"
		out=$(dx "$c" ping -6 -c 3 -i 0.5 -W 2 -M "do" -s $((m - 47)) -I "$src" "${SERVER6}" 2>&1)
		# iputils prints "Message too large" (sendmsg) once the client knows
		# the smaller path MTU, or "Packet too big" for the ICMPv6 error.
		if echo "$out" | grep -qiE 'too large|too long|too big|mtu'; then
			check "$c site $1: $((m + 1)) byte packets get packet too big" ok "$(echo "$out" | grep -iE 'too large|too long|too big|mtu' | head -n 1)"
		else
			check "$c site $1: $((m + 1)) byte packets get packet too big" fail "$(echo "$out" | tail -n 2 | tr '\n' ';')"
		fi
	done

	# The client knows the IPv4 MTU from DHCP (the route MTU). Else the
	# CLAT MTU is the tunnel MTU less 20 bytes.
	m4=$(dx "$c" ip -4 route show default | grep -oE 'mtu [0-9]+' | cut -d' ' -f2)
	m4=${m4:-${MTU4[$ap]:-$((${MTU[${ap}_muc01]} - 20))}}
	# 28 bytes: the IPv4 header and the ICMP echo header.
	out=$(dx "$c" ping -4 -c 3 -i 0.5 -W 2 -M "do" -s $((m4 - 28)) "${SERVER4}" 2>&1)
	echo "$out" | grep -qE ' [123] received' &&
		check "$c IPv4: $m4 byte packets arrive through the CLAT" ok "$(echo "$out" | grep received)" ||
		check "$c IPv4: $m4 byte packets arrive through the CLAT" fail "$(echo "$out" | tail -n 2 | tr '\n' ';')"
	out=$(dx "$c" ping -4 -c 3 -i 0.5 -W 2 -M "do" -s $((m4 - 27)) "${SERVER4}" 2>&1)
	echo "$out" | grep -qE ' [123] received' &&
		check "$c IPv4: $((m4 + 1)) byte packets do not pass" fail "$(echo "$out" | grep received)" ||
		check "$c IPv4: $((m4 + 1)) byte packets do not pass" ok "$(echo "$out" | grep -iE 'frag|mtu|too|received' | head -n 1)"
done
finish
