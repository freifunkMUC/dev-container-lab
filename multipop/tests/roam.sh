#!/usr/bin/env bash
# A client roams from ap-1 to ap-2 (both nodes are in the same mesh). It must
# get the prefixes of ap-2 and use them. A packet with an old ap-1 source must
# work or fail fast (ap-2 rejects foreign sources with ICMPv6 code 5); it must
# not wait for a timeout. Then the client goes back to ap-1.
. "$(dirname "$0")/common.sh"

C=client-1
old_a=$(addr_in "$C" "${PREFIX_A}")
new64_a=$(p64 "$(addr_in client-3 "${PREFIX_A}")")
new64_b=$(p64 "$(addr_in client-3 "${PREFIX_B}")")
log "$C has $old_a; the ap-2 prefixes are ${new64_a}::/64 and ${new64_b}::/64"

move() {
	sudo ip link set client1 nomaster
	sudo ip link set client1 master "aa-$1-lan"
	dx "$C" rdisc6 -1 -w 2000 lan > /dev/null 2>&1 || true
}

has_new() { dx "$C" ip -6 -o addr show dev lan scope global | grep -v deprecated | grep -q "$1:"; }

log "moving $C to ap-2"
move ap-2
t0=${SECONDS}
for p in "A ${new64_a}" "B ${new64_b}"; do
	set -- $p
	if wait_for 300 has_new "$2"; then
		check "$C gets the site $1 prefix of ap-2" ok "$2::/64 after $((SECONDS - t0)) s"
	else
		check "$C gets the site $1 prefix of ap-2" fail "$(dx "$C" ip -6 -o addr show dev lan scope global | tr '\n' ';')"
	fi
done

for p in "A ${new64_a}" "B ${new64_b}"; do
	set -- $p
	src=$(dx "$C" ip -6 -o addr show dev lan scope global | awk -v p="$2:" '$4 ~ "^"p {sub("/.*", "", $4); print $4; exit}')
	got=$(echo_src "$C" --interface "$src" "http://[${SERVER6}]:8080/")
	[ -n "$src" ] && [ "${got}" = "$src" ] && check "$C IPv6 from the ap-2 site $1 prefix" ok "${got}" ||
		check "$C IPv6 from the ap-2 site $1 prefix" fail "server saw '${got}' for '$src'"
done
got=$(echo_src "$C" -4 "http://${SERVER4}:8080/")
in_list "${got}" "${POOL4_A} ${POOL4_B}" && check "$C IPv4 after the roam" ok "${got}" ||
	check "$C IPv4 after the roam" fail "server saw '${got}'"

start=$(date +%s%N)
out=$(dx "$C" curl -s -S -m 8 --interface "$old_a" "http://[${SERVER6}]:8080/" 2>&1 | tr -d '[]\r')
ms=$((($(date +%s%N) - start) / 1000000))
if [ "${out}" = "$old_a" ]; then
	check "$C old ap-1 source" ok "works through the mesh (${ms} ms)"
elif [ "${ms}" -lt 4000 ]; then
	check "$C old ap-1 source" ok "fails fast (${ms} ms): ${out}"
else
	check "$C old ap-1 source" fail "timeout (${ms} ms): ${out}"
fi

log "moving $C back to ap-1"
move ap-1
wait_stable 600
finish
