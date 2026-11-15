#!/usr/bin/env bash
# Normal traffic over both sites: IPv6 from each prefix, DNS64 and NAT64 of
# each site, IPv4 through the CLAT, and the BGP routes per site.
. "$(dirname "$0")/common.sh"

routes=$(dx internet vtysh -c 'show bgp ipv6 unicast' 2>&1)
# The router ID of each gateway is its public IPv4.
for s in "2001:db8:a::/48 198.51.100.1 198.51.100.2" "2001:db8:b::/48 192.0.2.3 192.0.2.4" \
	"198.51.100.11/32 198.51.100.1" "192.0.2.13/32 192.0.2.3"; do
	set -- $s
	af=ipv6; case "$1" in *.*) af=ipv4 ;; esac
	want="${*:2}"
	got=$(dx internet vtysh -c "show bgp ${af} unicast $1 json" | jq -r '.paths[].peer.routerId' | sort | tr '\n' ' ')
	[ "${got% }" = "${want}" ] && check "$1 comes only from its site" ok "${got}" ||
		check "$1 comes only from its site" fail "from '${got}', want '${want}'"
done
echo "${routes}" >> "${LOG}"

for c in ${CLIENTS}; do
	a=$(addr_in "$c" "${PREFIX_A}")
	b=$(addr_in "$c" "${PREFIX_B}")
	[ -n "$a" ] && [ -n "$b" ] && check "$c has a prefix of each site" ok "$a $b" ||
		{ check "$c has a prefix of each site" fail "A=$a B=$b"; continue; }

	for p in "A $a ${DNS64_A} ${POOL4_A}" "B $b ${DNS64_B} ${POOL4_B}"; do
		set -- $p
		site=$1 src=$2 dns=$3 pool="$4 $5"
		got=$(echo_src "$c" --interface "${src}" "http://[${SERVER6}]:8080/")
		[ "${got}" = "${src}" ] && check "$c IPv6 from site $site" ok "${got}" ||
			check "$c IPv6 from site $site" fail "server saw '${got}'"

		aaaa=$(dx "$c" dig +short +time=3 +tries=2 -b "${src}" AAAA v4only.test.lab "@${dns}")
		[ "${aaaa}" = "${SERVER4_IN_NAT64}" ] && check "$c DNS64 of site $site" ok "${aaaa}" ||
			check "$c DNS64 of site $site" fail "'${aaaa}'"

		got=$(echo_src "$c" --interface "${src}" "http://[${SERVER4_IN_NAT64}]:8080/")
		in_list "${got}" "${pool}" && check "$c NAT64 of site $site" ok "${got}" ||
			check "$c NAT64 of site $site" fail "server saw '${got}', want one of ${pool}"
	done

	got=$(echo_src "$c" -4 "http://${SERVER4}:8080/")
	in_list "${got}" "${POOL4_A} ${POOL4_B}" && check "$c IPv4 through the CLAT" ok "${got}" ||
		check "$c IPv4 through the CLAT" fail "server saw '${got}'"
done

for ap in ${APS}; do
	check "$ap status" ok "$(node "$ap" 'cat /tmp/multipop/status' | tr '\n' ';')"
done
finish
