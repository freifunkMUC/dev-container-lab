#!/usr/bin/env bash
# Checks that the node sends ONE router advertisement with the prefixes of
# both sites. With one uradvd per site, each RA has only one prefix, and a
# client that keeps a prefix list per router (dhcpcd) can deprecate the
# other prefix. client-2 and client-4 use dhcpcd for IPv6.
. "$(dirname "$0")/common.sh"

# The number of prefixes in each RA that arrives in 10 s (one line per RA).
prefixes_per_ra() {
	dx "$1" rdisc6 -m -w 10000 lan 2>/dev/null | awk '
		/Hop limit/ { if (n != "") print n; n = 0 }
		/Prefix +:/ { n++ }
		END { if (n != "") print n }'
}

for ap in ${APS}; do
	n=$(node "${ap}" "pidof uradvd" | wc -w)
	[ "${n}" = 1 ] && check "${ap} runs one uradvd" ok ||
		check "${ap} runs one uradvd" fail "${n} instances"
	state=$(node "${ap}" "cat /tmp/multipop/ra-state" | tr '\n' ';')
	log "${ap} ra-state: ${state}"
done

for c in ${CLIENTS}; do
	counts=$(prefixes_per_ra "${c}" | tr '\n' ' ')
	if [ -n "${counts}" ] && [ -z "$(echo "${counts}" | tr ' ' '\n' | grep -vx 2 | grep .)" ]; then
		check "${c}: every RA has both prefixes" ok "prefixes per RA: ${counts}"
	else
		check "${c}: every RA has both prefixes" fail "prefixes per RA: '${counts}'"
	fi
done

# Watch the clients for 60 s: no address may become deprecated.
dep=""
for _ in $(seq 12); do
	for c in ${CLIENTS}; do
		for p in "${PREFIX_A}" "${PREFIX_B}"; do
			a=$(addr_in "${c}" "${p}")
			if [ -z "${a}" ]; then
				in_list "${c}:missing:${p}" "${dep}" || dep="${dep} ${c}:missing:${p}"
			elif deprecated "${c}" "${a}"; then
				in_list "${c}:${a}" "${dep}" || dep="${dep} ${c}:${a}"
			fi
		done
	done
	sleep 5
done
[ -z "${dep}" ] && check "no client address deprecated or missing in 60 s" ok ||
	check "no client address deprecated or missing in 60 s" fail "${dep# }"
finish
