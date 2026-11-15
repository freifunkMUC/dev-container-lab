#!/usr/bin/env bash
# RFC 6724 rule 8 (longest matching prefix). Both prefixes are preferred.
# To the DNS64 of a site, the client must use the address of that site. To a
# destination that matches no site better (the test server, 64:ff9b::/96),
# rule 8 is a tie: the source must be in a site, stay the same, and work.
. "$(dirname "$0")/common.sh"

src_to() { dx "$1" ip -6 route get "$2" | grep -oE 'src [0-9a-f:]+' | cut -d' ' -f2; }

for c in ${CLIENTS}; do
	for p in "A ${DNS64_A} ${PREFIX_A}" "B ${DNS64_B} ${PREFIX_B}"; do
		set -- $p
		s=$(src_to "$c" "$2")
		case "$s" in "$3"*) r=ok ;; *) r=fail ;; esac
		check "$c uses the site $1 address to the site $1 DNS64" "$r" "$2 from '$s'"
	done

	for d in "${SERVER6}" "${SERVER4_IN_NAT64}"; do
		srcs=$(for _ in 1 2 3 4 5; do src_to "$c" "$d"; done | sort -u)
		case "${srcs}" in
		"${PREFIX_A}"* | "${PREFIX_B}"*)
			[ "$(echo "${srcs}" | wc -l)" = 1 ] && r=ok || r=fail ;;
		*) r=fail ;;
		esac
		check "$c tie to $d: one source of a site" "$r" "$(echo "${srcs}" | tr '\n' ' ')"
		got=$(echo_src "$c" -6 "http://[$d]:8080/")
		case "$d" in
		"${SERVER6}") [ "${got}" = "${srcs}" ] && r=ok || r=fail ;;
		*) in_list "${got}" "${POOL4_A} ${POOL4_B}" && r=ok || r=fail ;;
		esac
		check "$c tie to $d: traffic works" "$r" "server saw '${got}'"
	done
done
finish
