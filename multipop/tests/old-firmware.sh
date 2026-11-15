#!/usr/bin/env bash
# A node with old firmware does not send caps=multiprefix. The two-site
# broker must answer it like a one-site broker: one concentrator with the
# top-level fields, no site, no pgws list and no primary_site.
. "$(dirname "$0")/common.sh"

ans=$(node ap-1 'k=$(wg genkey | wg pubkey); wget -qO- "http://broker.lab/config?pubkey=$(echo $k | sed "s/+/%2B/g; s/\//%2F/g; s/=/%3D/g")&nonce=oldfw$$&v6mtu=1500&version=old" | head -n -1' 60 | tr -d '\r' | grep '^{' | tail -n 1)
echo "${ans}" >> "${LOG}"
if ! echo "${ans}" | jq -e . >/dev/null 2>&1; then
	check "the broker answers the old node" fail "not JSON: ${ans:0:300}"
	finish; exit
fi
check "the broker answers the old node" ok "$(echo "${ans}" | jq -c 'del(.signature)' | cut -c1-300)"
n=$(echo "${ans}" | jq '.concentrators | length')
[ "$n" = 1 ] && check "one concentrator" ok || check "one concentrator" fail "$n"
extra=$(echo "${ans}" | jq -r '[(.primary_site // empty), (.concentrators[] | .site // empty, (.pgws // empty | "pgws"))] | join(" ")')
[ -z "$extra" ] && check "no multi-site fields" ok || check "no multi-site fields" fail "$extra"
r=$(echo "${ans}" | jq -r '.range6 // .concentrators[0].range6 // empty')
case "$r" in "${PREFIX_A}"*) check "the old node gets the primary site" ok "$r" ;;
*) check "the old node gets the primary site" fail "range6 '$r'" ;; esac
finish
