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
	sudo ip link set aa-client1 nomaster
	sudo ip link set aa-client1 master "aa-$1-lan"
	dx "$C" rdisc6 -1 -w 2000 lan > /dev/null 2>&1 || true
}

# A usable address: not deprecated, and duplicate address detection is done.
has_new() { dx "$C" ip -6 -o addr show dev lan scope global | grep -v -e deprecated -e tentative | grep -q "$1:"; }

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
	src=$(dx "$C" ip -6 -o addr show dev lan scope global | grep -v tentative |
		awk -v p="$2:" '$4 ~ "^"p {sub("/.*", "", $4); print $4; exit}')
	# br-client bridges bat0, so the router of ap-1 stays reachable through
	# the mesh. ap-1 rejects the ap-2 prefixes. The client drops that router
	# when its router lifetime (30 s) ends, because ap-1 RAs do not cross the
	# mesh.
	works() { [ -n "$src" ] && [ "$(echo_src "$C" -m 3 --interface "$src" "http://[${SERVER6}]:8080/")" = "$src" ]; }
	t1=${SECONDS}
	if wait_for 60 works; then
		check "$C IPv6 from the ap-2 site $1 prefix" ok "$src after $((SECONDS - t1)) s"
	else
		check "$C IPv6 from the ap-2 site $1 prefix" fail "server saw '$(echo_src "$C" -m 3 --interface "$src" "http://[${SERVER6}]:8080/")' for '$src'; $(dx "$C" sh -c "ip -6 route show default; ip -6 route get ${SERVER6} from $src; ip -6 neigh show dev lan" 2>&1 | tr '\n' ';')"
	fi
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
# Remove the ap-2 addresses and routes, so the next tests use the ap-1
# prefixes only (a real client keeps them until the valid lifetime ends).
dx "$C" sh -c "ip -6 -o addr show dev lan scope global | awk '\$4 ~ \"^(${new64_a}|${new64_b}):\" {print \$4}' |
	xargs -r -n 1 ip -6 addr del dev lan; ip -6 route flush dev lan proto ra"
dx "$C" rdisc6 -1 -w 2000 lan > /dev/null 2>&1 || true
wait_stable 600
finish
