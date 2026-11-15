#!/usr/bin/env bash
# Shows which prefix the clients use as source when the application does not
# choose. In active/active both prefixes are preferred, so the kernel source
# address selection (RFC 6724) chooses. This test only records the choice.
. "$(dirname "$0")/common.sh"

na=0 nb=0
for c in ${CLIENTS}; do
	rsrc=$(dx "$c" ip -6 route get "${SERVER6}" | grep -oE 'src [0-9a-f:]+' | cut -d' ' -f2)
	got=$(echo_src "$c" -6 "http://[${SERVER6}]:8080/")
	dns=$(dx "$c" ip -6 route get "${DNS64_B}" | grep -oE 'src [0-9a-f:]+' | cut -d' ' -f2)
	case "${got}" in
	"${PREFIX_A}"*) site=A; na=$((na + 1)) ;;
	"${PREFIX_B}"*) site=B; nb=$((nb + 1)) ;;
	*) site=none ;;
	esac
	[ "${site}" != none ] && [ "${got}" = "${rsrc}" ] &&
		check "$c uses site ${site} as source" ok "server saw ${got}; route get: ${rsrc}; to site B DNS64: ${dns}" ||
		check "$c source address" fail "server saw '${got}', route get '${rsrc}'"
done
check "summary" ok "site A: ${na} clients, site B: ${nb} clients"
finish
