#!/usr/bin/env bash
# One pgw of site B fails (the internet loses its link). The nodes that use
# it must change to the other pgw of site B. IPv6 and IPv4 are checked
# separately: the site B /63 stays the same and works again through the new
# pgw; IPv4 keeps working (on the active tunnel, or again after the change).
# A pgw change inside a site must not deprecate the prefix: site B stays up
# and preferred on the nodes, and the clients keep a preferred site B address.
# The node reports the change to the broker, and the old pgw must remove the
# route of the /63 within a few seconds (without the broker: after 180 s).
# Metrics: the outage that the clients see (see meas_start in common.sh),
# the detection time on the node, and the time until the old route is gone.
. "$(dirname "$0")/common.sh"
# BROKER_DOWN=1: the broker on gw01 is stopped first (see broker-down.sh).
CASE=pgw_switch
[ "${BROKER_DOWN:-0}" = 1 ] && CASE=broker_down

clear_damping
ifc=$(site_ifc ap-1 vie01)
gw=$(pgw_gw ap-1 "$ifc")
case "$gw" in gw03) other=gw04 ;; gw04) other=gw03 ;; *)
	check "ap-1 uses a site B pgw" fail "endpoint '$gw'"; finish; exit ;;
esac
check "ap-1 uses a site B pgw" ok "$ifc to $gw"

declare -A SRC_B
for c in ${CLIENTS}; do SRC_B[$c]=$(addr_in "$c" "${PREFIX_B}"); done

if [ "${BROKER_DOWN:-0}" = 1 ]; then
	node gateway-gw01 "echo ffmuc | sudo -S systemctl stop wgkex-broker" 60 >> "${LOG}" 2>&1
	st=$(node gateway-gw01 "systemctl is-active wgkex-broker" 30 | tr -d '\r' | tail -n 1)
	[ "$st" != active ] && check "broker on gw01 is stopped" ok "$st" ||
		check "broker on gw01 is stopped" fail "$st"
fi

# Watch the site B addresses of the clients during the change. The serial
# console allows one client only, so the nodes are checked after the change
# (clear_damping removed their state change history).
WATCH="${RESULTS}/${TEST}.watch"
: > "${WATCH}"
watch() {
	while :; do
		for c in ${CLIENTS}; do
			dx "$c" ip -6 -o addr show dev lan | grep "${PREFIX_B}" | grep deprecated |
				sed "s/^/$c /" >> "${WATCH}"
		done
		sleep 2
	done
}

# The /63 of ap-1 in site B starts with the LAN /64 of client-1.
net63="$(p64 "${SRC_B[client-1]}")::/63"
# route_on <gw>: prints "yes" or "no", or nothing if the console fails.
route_on() {
	node "gateway-$1" "ip -6 route show ${net63} | grep -c . ; echo END" 30 | tr -d '\r' |
		awk '/^[0-9]+$/ {n = $1} /^END/ {print (n > 0 ? "yes" : "no")}'
}
if [ "$(route_on "$gw")" = yes ]; then
	check "$gw has the route of ${net63}" ok
else
	check "$gw has the route of ${net63}" fail "$(node "gateway-$gw" 'ip -6 route show dev wg-nodes' 30 | tr '\n' ';')"
fi

meas_start "${CASE}" client-1 "${SRC_B[client-1]}"
log "cutting $gw"
meas_event "${CASE}"
dx internet ip link set "$gw" down
t0=${SECONDS}
watch &
watcher=$!

# The old pgw removes the route. Without the broker, the worker removes it
# when the handshake is older than 180 s.
GONE="${RESULTS}/${TEST}.route-gone"
rm -f "${GONE}"
(
	end=$((SECONDS + 300))
	while [ "${SECONDS}" -lt "${end}" ]; do
		[ "$(route_on "$gw")" = no ] && { now > "${GONE}"; break; }
		sleep 1
	done
) &
poller=$!

uses_other() { [ "$(pgw_gw ap-1 "$ifc")" = "$other" ]; }
b_works() { [ "$(echo_src "$1" -6 -m 5 --interface "$2" "http://[${SERVER6}]:8080/")" = "$2" ]; }
if wait_for 60 uses_other; then
	check "ap-1 changes to $other" ok "after $((SECONDS - t0)) s"
else
	check "ap-1 changes to $other" fail "$(node ap-1 "wg show $ifc; cat /tmp/multipop/status" | tr '\n' ';')"
fi

# IPv6: the site B prefix of each client works again through the new pgw.
for c in ${CLIENTS}; do
	b=${SRC_B[$c]}
	if wait_for 60 b_works "$c" "$b"; then
		check "$c IPv6: the same site B address works again" ok "$b after $((SECONDS - t0)) s"
	else
		check "$c IPv6: the same site B address works again" fail "$b"
	fi
done
for ap in ${APS}; do
	if wait_for 60 ap_has "$ap" vie01 'up .* preferred=300'; then
		check "$ap: site B is up" ok "$(node "$ap" 'cat /tmp/multipop/status' | grep vie01)"
	else
		check "$ap: site B is up" fail "$(node "$ap" 'cat /tmp/multipop/status' | tr '\n' ';')"
	fi
done

kill "${watcher}" 2>/dev/null
wait "${watcher}" 2>/dev/null
if [ -s "${WATCH}" ]; then
	check "clients: site B stays preferred during the pgw change" fail "$(sort -u "${WATCH}" | head -n 5 | tr '\n' ';')"
else
	check "clients: site B stays preferred during the pgw change" ok "no site B address was deprecated"
fi
for ap in ${APS}; do
	n=$(node "$ap" "cat /tmp/multipop/$(site_ifc "$ap" vie01).changes 2>/dev/null | grep -c ." | tr -d '\r' | tail -n 1)
	[ "${n:-0}" = 0 ] && check "$ap: site B did not change state" ok "0 state changes" ||
		check "$ap: site B did not change state" fail "${n} state changes: $(node "$ap" 'logread | grep "vie01) is"' | tr '\n' ';')"
done

# IPv4: through the CLAT of the active tunnel.
for c in ${CLIENTS}; do
	got=""
	for _ in $(seq 12); do
		got=$(echo_src "$c" -4 "http://${SERVER4}:8080/")
		in_list "${got}" "${POOL4_A} ${POOL4_B}" && break
		sleep 5
	done
	in_list "${got}" "${POOL4_A} ${POOL4_B}" && check "$c IPv4 works" ok "${got}" ||
		check "$c IPv4 works" fail "server saw '${got}'"
done

sleep 5
meas_stop "${CASE}"
wait "${poller}"
route_gone=$(cat "${GONE}" 2>/dev/null)

# The times on the node, in seconds after the cut.
sw=$(node_event ap-1 pgw_switch "$ifc" "${CASE}")
rep=$(node_event ap-1 switch_reported "$ifc" "${CASE}")
metric ".${CASE}.node" "$(jq -n --arg s "${sw}" --arg r "${rep}" \
	'{detection_s: ($s | tonumber? // null), switch_reported_s: ($r | tonumber? // null)}')"
[ -n "${sw}" ] && check "ap-1 detects the failure and changes the pgw" ok "${sw} s after the cut" ||
	check "ap-1 detects the failure and changes the pgw" fail "no pgw_switch event"
if [ -n "${route_gone}" ]; then
	gone_s=$(echo "${route_gone} ${MEAS_EVENT[${CASE}]}" | awk '{printf "%.0f", $1 - $2}')
	metric ".${CASE}.node.old_route_gone_s" "${gone_s}"
else
	gone_s=""
fi
if [ "${BROKER_DOWN:-0}" = 1 ]; then
	# The 180 s handshake timeout of the worker is the safety net.
	[ -n "${gone_s}" ] && check "$gw removes ${net63} without the broker" ok "${gone_s} s after the cut" ||
		check "$gw removes ${net63} without the broker" fail "the route is still there"
elif [ -n "${gone_s}" ] && [ -n "${rep}" ] && [ "$((gone_s - rep))" -le 10 ]; then
	check "$gw removes ${net63} a few seconds after the report" ok "${gone_s} s after the cut, report at ${rep} s"
else
	check "$gw removes ${net63} a few seconds after the report" fail "gone at '${gone_s}' s, report at '${rep}' s"
fi

log "restoring $gw"
dx internet ip link set "$gw" up
if [ "${BROKER_DOWN:-0}" = 1 ]; then
	node gateway-gw01 "echo ffmuc | sudo -S systemctl start wgkex-broker" 60 >> "${LOG}" 2>&1
fi
clear_damping
wait_stable 600
finish
