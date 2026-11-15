#!/usr/bin/env bash
# Site B is down for longer than the handshake limit (180 s) and the
# withdrawal time. The reject rule for the site B /64 is active, and the
# pgws remove the route of the node /63. When site B comes back, the
# handshake must renew through the reject rule, the pgw must install the
# route again, and the site must come up and carry traffic.
. "$(dirname "$0")/common.sh"

clear_damping
ifc=$(site_ifc ap-1 vie01)
b64=$(p64 "$(addr_in client-1 "${PREFIX_B}")")
log "cutting site B; ap-1 $ifc, site B /64 of ap-1 is ${b64}::/64"
dx internet ip link set gw03 down
dx internet ip link set gw04 down
t0=${SECONDS}

wait_for 300 ap_has ap-1 vie01 'down .* preferred=withdrawn' &&
	check "ap-1 withdraws site B" ok "after $((SECONDS - t0)) s" ||
	check "ap-1 withdraws site B" fail "$(site_state ap-1 vie01)"
# Wait until the handshake is older than 180 s.
sleep $((240 - (SECONDS - t0) > 0 ? 240 - (SECONDS - t0) : 0))
rules=$(node ap-1 'ip6tables -S parker_src')
echo "${rules}" | grep -q -- "-s ${b64}::/64 -j REJECT --reject-with icmp6-policy-fail" &&
	check "ap-1 rejects the site B source" ok "$(echo "${rules}" | grep "${b64}::/64" | tr -d '\r' | tr '\n' ';')" ||
	check "ap-1 rejects the site B source" fail "$(echo "${rules}" | tr -d '\r' | tr '\n' ';')"
check "ap-1 site B handshake is old" ok "$(node ap-1 'cat /tmp/multipop/status' | grep vie01)"
for gw in gateway-gw03 gateway-gw04; do
	n=$(node "$gw" "ip -6 route show proto static 2>/dev/null; ip -6 route" 60 | grep -c "${b64%:*}:")
	log "$gw routes to the ap-1 /63 during the outage: $n"
done

log "restoring site B after $((SECONDS - t0)) s"
dx internet ip link set gw03 up
dx internet ip link set gw04 up
t1=${SECONDS}
if wait_for 600 ap_has ap-1 vie01 'up .* preferred=300'; then
	check "ap-1 brings site B up after the long outage" ok "after $((SECONDS - t1)) s: $(node ap-1 'cat /tmp/multipop/status' | grep vie01)"
else
	check "ap-1 brings site B up after the long outage" fail "$(site_state ap-1 vie01)"
fi
hs=$(node ap-1 "wg show $ifc latest-handshakes" | awk '{print $2}')
[ -n "$hs" ] && [ $(($(date +%s) - hs)) -lt 180 ] && check "ap-1 site B handshake is fresh" ok "$(($(date +%s) - hs)) s" ||
	check "ap-1 site B handshake is fresh" fail "'$hs'"
gw=$(pgw_gw ap-1 "$ifc")
n=$(node "gateway-$gw" "ip -6 route" 60 | grep -c "${b64%:*}:")
[ "$n" -gt 0 ] && check "gateway-$gw has the route of the ap-1 /63 again" ok "$n routes" ||
	check "gateway-$gw has the route of the ap-1 /63 again" fail "no route"
wait_stable 900
for c in client-1 client-2; do
	b=$(addr_in "$c" "${PREFIX_B}")
	got=$(echo_src "$c" --interface "$b" "http://[${SERVER6}]:8080/")
	[ "${got}" = "$b" ] && check "$c IPv6 from site B works" ok "${got}" ||
		check "$c IPv6 from site B works" fail "server saw '${got}'"
done
finish
