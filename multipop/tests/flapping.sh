#!/usr/bin/env bash
# Site B flaps: its links go down and up again and again. After more than 3
# state changes in 10 minutes the node must keep site B down for the penalty
# time (30 s, then double each time), also while the probes work. Then site B
# must come up again. Metrics (case flapping): the outage that the clients
# see, and the penalty time.
. "$(dirname "$0")/common.sh"
CASE=flapping

clear_damping
cut() { dx internet ip link set gw03 "$1"; dx internet ip link set gw04 "$1"; }
penalty() { node ap-1 'cat /tmp/multipop/status' | awk '$2 == "vie01" {sub("penalty=", "", $9); print $9 + 0}'; }
in_penalty() { [ "$(penalty)" -gt 0 ]; }
up_or_penalty() { ap_has ap-1 vie01 'up ' || in_penalty; }

meas_start "${CASE}"
meas_event "${CASE}"
t0=${SECONDS}
for n in 1 2 3 4; do
	log "flap $n: cutting site B"
	cut down
	wait_for 60 ap_has ap-1 vie01 'down ' ||
		{ check "flap $n: site B goes down" fail "$(site_state ap-1 vie01)"; break; }
	log "flap $n: restoring site B"
	cut up
	wait_for 120 up_or_penalty ||
		{ check "flap $n: site B comes up" fail "$(site_state ap-1 vie01)"; break; }
	in_penalty && break
done
cut up

if in_penalty; then
	check "ap-1 sets the penalty" ok "after $((SECONDS - t0)) s: $(node ap-1 'cat /tmp/multipop/status' | grep vie01)"
	p=$(penalty)
	metric ".${CASE}.node" "$(jq -n --argjson p "${p}" '{penalty_s: $p}')"
	sleep $((p / 2))
	if ap_has ap-1 vie01 'down '; then
		check "ap-1 keeps site B down during the penalty" ok "$(node ap-1 'cat /tmp/multipop/status' | grep vie01)"
	else
		check "ap-1 keeps site B down during the penalty" fail "$(site_state ap-1 vie01)"
	fi
	if wait_for $((p + 120)) ap_has ap-1 vie01 'up .* preferred=300'; then
		check "ap-1 brings site B up after the penalty" ok "after $((SECONDS - t0)) s"
	else
		check "ap-1 brings site B up after the penalty" fail "$(site_state ap-1 vie01)"
	fi
else
	check "ap-1 sets the penalty" fail "$(node ap-1 'cat /tmp/multipop/status' | grep vie01)"
fi
sleep 5
meas_stop "${CASE}"
node ap-1 'logread -e mp-node | tail -n 30' >> "${LOG}" 2>&1
clear_damping
wait_stable 300
finish
