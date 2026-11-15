#!/usr/bin/env bash
# Site B fails: the internet loses the links to gw03 and gw04. The nodes must
# deprecate the site B prefix, reject it with ICMPv6 code 5, keep IPv6 on
# site A, move IPv4 to site A, and stop announcing site B after 120 s. The
# client addresses of site B expire after the valid lifetime (600 s).
# Metrics (case site_failover_b): the outage that the clients see, and the
# detection time on the node.
. "$(dirname "$0")/common.sh"
CASE=site_failover_b

clear_damping

declare -A SRC_B
for c in ${CLIENTS}; do SRC_B[$c]=$(addr_in "$c" "${PREFIX_B}"); done

meas_start "${CASE}"
log "cutting site B"
meas_event "${CASE}"
dx internet ip link set gw03 down
dx internet ip link set gw04 down
t0=${SECONDS}

for ap in ${APS}; do
	if wait_for 60 ap_has "$ap" vie01 "down "; then
		check "$ap sees site B down" ok "after $((SECONDS - t0)) s: $(site_state "$ap" vie01)"
	else
		check "$ap sees site B down" fail "$(node "$ap" 'cat /tmp/multipop/status' | tr '\n' ';')"
	fi
done

for c in ${CLIENTS}; do
	b=${SRC_B[$c]}
	if wait_for 60 deprecated "$c" "$b"; then
		check "$c site B address is deprecated" ok "$b after $((SECONDS - t0)) s"
	else
		check "$c site B address is deprecated" fail "$(dx "$c" ip -6 addr show dev lan | grep "$b")"
	fi

	start=$(date +%s%N)
	err=$(dx "$c" curl -s -S -m 8 --interface "$b" "http://[${SERVER6}]:8080/" 2>&1)
	ms=$((($(date +%s%N) - start) / 1000000))
	trace=$(dx "$c" timeout 5 traceroute -6 -n -q 1 -m 3 -s "$b" "${SERVER6}" 2>&1 | tail -n +2 | tr '\n' ';')
	if [ "${ms}" -lt 4000 ] && echo "${err}" | grep -q '^curl:'; then
		check "$c site B source is rejected fast" ok "${ms} ms: ${err}; traceroute: ${trace}"
	else
		check "$c site B source is rejected fast" fail "${ms} ms: ${err}"
	fi

	got=$(echo_src "$c" -6 "http://[${SERVER6}]:8080/")
	case "${got}" in "${PREFIX_A}"*) r=ok ;; *) r=fail ;; esac
	check "$c default source moves to site A" "$r" "server saw '${got}'"

	got=""
	for _ in $(seq 12); do
		got=$(echo_src "$c" -4 "http://${SERVER4}:8080/")
		in_list "${got}" "${POOL4_A}" && break
		sleep 5
	done
	in_list "${got}" "${POOL4_A}" && check "$c IPv4 fails over to site A" ok "${got}" ||
		check "$c IPv4 fails over to site A" fail "server saw '${got}'"
done

meas_stop "${CASE}"
d=$(node_event ap-1 site_down . "${CASE}")
metric ".${CASE}.node" "$(jq -n --arg d "$d" '{detection_s: ($d | tonumber? // null)}')"

for ap in ${APS}; do
	if wait_for 300 ap_has "$ap" vie01 withdrawn; then
		check "$ap stops announcing site B" ok "after $((SECONDS - t0)) s"
	else
		check "$ap stops announcing site B" fail "$(site_state "$ap" vie01)"
	fi
	node "$ap" 'logread -e mp-node | tail -n 20' >> "${LOG}" 2>&1
done

gone() { ! dx "$1" ip -6 addr show dev lan | grep -q "$2/"; }
for c in ${CLIENTS}; do
	b=${SRC_B[$c]}
	if wait_for 780 gone "$c" "$b"; then
		check "$c site B address expires" ok "after $((SECONDS - t0)) s"
	else
		check "$c site B address expires" fail "$(dx "$c" ip -6 addr show dev lan | grep "$b")"
	fi
done
finish
