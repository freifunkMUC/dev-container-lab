#!/usr/bin/env bash
# Site B comes back. The nodes must announce the site B prefix again and the
# clients must use it again.
. "$(dirname "$0")/common.sh"

clear_damping

log "restoring site B"
dx internet ip link set gw03 up
dx internet ip link set gw04 up
t0=${SECONDS}

for ap in ${APS}; do
	if wait_for 900 ap_has "$ap" vie01 'up .* preferred=300'; then
		check "$ap sees site B up" ok "after $((SECONDS - t0)) s: $(site_state "$ap" vie01)"
	else
		check "$ap sees site B up" fail "$(node "$ap" 'cat /tmp/multipop/status' | tr '\n' ';')"
	fi
done

pref_b() { dx "$1" ip -6 -o addr show dev lan scope global | grep "${PREFIX_B}" | grep -vq deprecated; }
for c in ${CLIENTS}; do
	if ! wait_for 300 pref_b "$c"; then
		check "$c gets a preferred site B address" fail "$(dx "$c" ip -6 -o addr show dev lan)"
		continue
	fi
	b=$(addr_in "$c" "${PREFIX_B}")
	check "$c gets a preferred site B address" ok "$b after $((SECONDS - t0)) s"
	got=$(echo_src "$c" --interface "$b" "http://[${SERVER6}]:8080/")
	[ "${got}" = "$b" ] && check "$c IPv6 from site B works again" ok "${got}" ||
		check "$c IPv6 from site B works again" fail "server saw '${got}'"
	got=$(echo_src "$c" --interface "$b" "http://[${SERVER4_IN_NAT64}]:8080/")
	in_list "${got}" "${POOL4_B}" && check "$c NAT64 of site B works again" ok "${got}" ||
		check "$c NAT64 of site B works again" fail "server saw '${got}'"
	got=$(echo_src "$c" -4 "http://${SERVER4}:8080/")
	in_list "${got}" "${POOL4_A} ${POOL4_B}" && check "$c IPv4 works" ok "${got}" ||
		check "$c IPv4 works" fail "server saw '${got}'"
done
finish
