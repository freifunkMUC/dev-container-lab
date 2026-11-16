#!/usr/bin/env bash
# Site A (the primary site, with IPv4) fails and comes back.
# 1. Cut gw01 and gw02. The nodes must mark site A down, move IPv4 (the CLAT)
#    to site B at once, and new IPv6 connections must use site B.
# 2. Restore site A. After 3 good probes, a fresh handshake and the dwell
#    (about 10 s), the nodes must move IPv4 back to site A.
# Metrics (cases site_failover_a and switch_back): the outage that the
# clients see, and the times of the node events after the cut or the restore.
. "$(dirname "$0")/common.sh"

clear_damping
wait_stable 300
cut() { dx internet ip link set gw01 "$1"; dx internet ip link set gw02 "$1"; }
ipv4_in() { in_list "$(echo_src "$1" -4 -m 3 "http://${SERVER4}:8080/")" "$2"; }
new6_in() { case "$(echo_src "$1" -6 -m 3 "http://[${SERVER6}]:8080/")" in "$2"*) return 0 ;; esac; return 1; }

# node_times <case> <site event>: the detection and the active tunnel change
# on ap-1, in seconds after the event of the case.
node_times() {
	local d a
	d=$(node_event ap-1 "$2" . "$1")
	a=$(node_event ap-1 active . "$1")
	metric ".$1.node" "$(jq -n --arg d "$d" --arg a "$a" \
		'{detection_s: ($d | tonumber? // null), active_change_s: ($a | tonumber? // null)}')"
}

CASE=site_failover_a
meas_start "${CASE}"
log "cutting site A"
meas_event "${CASE}"
cut down
t0=${SECONDS}
for ap in ${APS}; do
	if wait_for 60 ap_has "$ap" muc01 "down "; then
		check "$ap sees site A down" ok "after $((SECONDS - t0)) s"
	else
		check "$ap sees site A down" fail "$(node "$ap" 'cat /tmp/multipop/status' | tr '\n' ';')"
	fi
done
for c in ${CLIENTS}; do
	if wait_for 60 ipv4_in "$c" "${POOL4_B}"; then
		check "$c IPv4 moves to site B" ok "after $((SECONDS - t0)) s"
	else
		check "$c IPv4 moves to site B" fail "server saw '$(echo_src "$c" -4 "http://${SERVER4}:8080/")'"
	fi
	if wait_for 60 new6_in "$c" "${PREFIX_B}"; then
		check "$c new IPv6 connections use site B" ok "after $((SECONDS - t0)) s"
	else
		check "$c new IPv6 connections use site B" fail "server saw '$(echo_src "$c" -6 "http://[${SERVER6}]:8080/")'"
	fi
done
sleep 5
meas_stop "${CASE}" a
node_times "${CASE}" site_down

CASE=switch_back
clear_damping
meas_start "${CASE}"
log "restoring site A"
meas_event "${CASE}"
cut up
t0=${SECONDS}
for ap in ${APS}; do
	if wait_for 120 ap_has "$ap" muc01 'up .* preferred=300'; then
		check "$ap sees site A up" ok "after $((SECONDS - t0)) s"
	else
		check "$ap sees site A up" fail "$(node "$ap" 'cat /tmp/multipop/status' | tr '\n' ';')"
	fi
done
for c in ${CLIENTS}; do
	if wait_for 120 ipv4_in "$c" "${POOL4_A}"; then
		check "$c IPv4 moves back to site A" ok "after $((SECONDS - t0)) s"
	else
		check "$c IPv4 moves back to site A" fail "server saw '$(echo_src "$c" -4 "http://${SERVER4}:8080/")'"
	fi
done
sleep 5
meas_stop "${CASE}"
node_times "${CASE}" site_up

clear_damping
wait_stable 300
finish
