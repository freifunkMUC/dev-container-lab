#!/bin/sh
# Smoke test for multipop/patches/uradvd.patch. Needs only docker.
#
# It builds uradvd with and without the patch, and runs it on a veth pair.
# A dhcpcd client and rdisc6 on the other end look at the RAs:
#   1. original, two instances (one per prefix): each RA has only one
#      prefix (this is the bug; the test expects it). Whether the client
#      deprecates the missing prefix depends on the client; the test only
#      reports what dhcpcd does.
#   2. patched, one instance: one RA has both prefixes, nothing deprecated,
#   3. SIGHUP with preferred 0 for B: B deprecated at once, A not,
#   4. B left out: A stays preferred,
#   5. B back: B preferred again,
#   6. a bad state file: uradvd keeps the old state,
#   7. SIGHUP sends three RAs, at least 3 s apart.
# Exit 0 only if all steps pass.

set -eu
cd "$(dirname "$0")/../.."
exec docker run --rm -i --privileged -v "${PWD}/multipop/patches:/patches:ro" \
	alpine:3.20 sh -s <<'INNER'
set -u
COMMIT=9c44a2cae9e3573047f152c716950807767a8da3
A=2001:db8:a:2::
B=2001:db8:b:2::
fails=0
ok() { echo "PASS: $*"; }
nok() { echo "FAIL: $*"; fails=$((fails + 1)); }

apk add -q build-base linux-headers curl patch dhcpcd ndisc6 iproute2 tcpdump >/dev/null
mkdir /src && cd /src
curl -sfL "https://codeload.github.com/freifunkMUC/uradvd/tar.gz/${COMMIT}" | tar xz --strip-components 1
gcc -Os -DVERSION='"orig"' -o /uradvd-orig uradvd.c
patch -s -p1 < /patches/uradvd.patch
gcc -Wall -Wextra -Werror -Os -DVERSION='"mp"' -o /uradvd uradvd.c || { echo "FAIL: build"; exit 1; }

ip netns add cl
ip link add r type veth peer name c netns cl
ip link set r up
ip -n cl link set c up
ip -n cl link set lo up
sleep 2
FAST="--max-router-adv-interval 4 --min-router-adv-interval 3"

client_up() {
	ip netns exec cl dhcpcd -6 -q -b --nohook resolv.conf c >/dev/null 2>&1
}
client_down() {
	ip netns exec cl dhcpcd -x c >/dev/null 2>&1
	sleep 1
	ip -n cl -6 addr flush dev c scope global
}
# Lines: "<prefix> deprecated" or "<prefix> preferred", one per address.
addrs() {
	ip -n cl -6 addr show dev c scope global | awk '
		/inet6/ { split($2, a, ":"); p = a[1] ":" a[2] ":" a[3] ":" a[4] "::"; next }
		/preferred_lft/ { print p, ($4 == "0sec" ? "deprecated" : "preferred") }'
}
# Watch the client for $1 seconds; print each prefix that was deprecated.
watch_deprecated() {
	i=0
	while [ "$i" -lt "$1" ]; do
		addrs | awk '$2 == "deprecated" { print $1 }'
		sleep 1
		i=$((i + 1))
	done | sort -u
}
# The number of prefixes in each RA seen in 10 s, one line per RA.
ra_sizes() {
	ip netns exec cl rdisc6 -m -w 10000 c 2>/dev/null | awk '
		/Hop limit/ { if (n != "") print n; n = 0 }
		/Prefix +:/ { n++ }
		END { if (n != "") print n }'
}
# One RA after a solicitation, as "<prefix> <preferred>" lines.
ra() {
	ip netns exec cl rdisc6 -1 -w 2000 c 2>/dev/null | awk '
		/Prefix +:/ { p = $3; sub("/64", "", p) }
		/Pref. time/ { print p, $4 }'
}
pref_of() { ra | awk -v p="$1" '$1 == p { print $2 }'; }

echo "--- 1. original uradvd, two instances"
/uradvd-orig -i r -p "${A}/64" $FAST >/dev/null 2>&1 &
o1=$!
/uradvd-orig -i r -p "${B}/64" $FAST >/dev/null 2>&1 &
o2=$!
sizes=$(ra_sizes | sort -u | tr '\n' ' ')
[ "${sizes}" = "1 " ] && ok "two instances: each RA has only one prefix (the bug)" ||
	nok "two instances: prefixes per RA: ${sizes}"
client_up
sleep 8
dep=$(watch_deprecated 20 | tr '\n' ' ')
echo "INFO: $(dhcpcd --version | head -1) with two instances deprecates: ${dep:-nothing}"
kill "$o1" "$o2"
client_down

echo "--- 2. patched uradvd, one instance"
printf '%s\n' "${A}/64,120,180" "${B}/64,120,180" "rdnss 2001:db8:a::53" > /state
/uradvd -i r --state-file /state $FAST 2>/uradvd.err &
u=$!
sizes=$(ra_sizes | sort -u | tr '\n' ' ')
[ "${sizes}" = "2 " ] && ok "one instance: every RA has both prefixes" ||
	nok "one instance: prefixes per RA: ${sizes}"
client_up
sleep 8
n=$(ra | grep -c -e "^${A} 120" -e "^${B} 120")
[ "$n" = 2 ] && ok "one RA has both prefixes, preferred 120" || nok "one RA: $(ra | tr '\n' ';')"
dep=$(watch_deprecated 20 | tr '\n' ' ')
[ -z "${dep}" ] && ok "one instance: nothing deprecated in 20 s" || nok "one instance: deprecated ${dep}"
[ "$(addrs | grep -c preferred)" = 2 ] && ok "client has both addresses" || nok "client: $(addrs | tr '\n' ';')"

echo "--- 3. SIGHUP: B preferred 0"
printf '%s\n' "${A}/64,120,180" "${B}/64,0,180" > /state
kill -HUP "$u"
sleep 2
[ "$(pref_of "$B")" = 0 ] && [ "$(pref_of "$A")" = 120 ] && ok "RA: A 120, B 0" || nok "RA: $(ra | tr '\n' ';')"
addrs | grep -q "^${B} deprecated" && addrs | grep -q "^${A} preferred" &&
	ok "client: B deprecated, A preferred" || nok "client: $(addrs | tr '\n' ';')"
kill -0 "$u" && ok "uradvd did not restart (same pid)" || nok "uradvd is gone"

echo "--- 4. B left out"
printf '%s\n' "${A}/64,120,180" > /state
kill -HUP "$u"
sleep 2
[ "$(ra | wc -l)" = 1 ] && ok "RA has only A" || nok "RA: $(ra | tr '\n' ';')"
dep=$(watch_deprecated 10 | grep -v "^${B}$" | tr '\n' ' ')
[ -z "${dep}" ] && ok "A stays preferred" || nok "deprecated: ${dep}"

echo "--- 5. B back"
printf '%s\n' "${A}/64,120,180" "${B}/64,120,180" > /state
kill -HUP "$u"
sleep 3
addrs | grep -q "^${B} preferred" && addrs | grep -q "^${A} preferred" &&
	ok "client: both preferred again" || nok "client: $(addrs | tr '\n' ';')"

echo "--- 6. bad state file"
printf '%s\n' "${A}/64,200,100" > /state
kill -HUP "$u"
sleep 2
[ "$(ra | wc -l)" = 2 ] && grep -q "ignoring state file" /uradvd.err &&
	ok "bad file ignored, old state kept" || nok "RA: $(ra | tr '\n' ';')"

kill "$u"

echo "--- 7. SIGHUP sends three RAs, at least 3 s apart"
client_down
printf '%s\n' "${A}/64,120,180" "${B}/64,120,180" > /state
/uradvd -i r --state-file /state --max-router-adv-interval 200 --min-router-adv-interval 150 2>/dev/null &
u=$!
sleep 8
ip netns exec cl timeout 13 tcpdump -l -n -tt -i c icmp6 2>/dev/null |
	awk '/router advertisement/ { print int($1) }' > /burst &
sleep 1
kill -HUP "$u"
sleep 14
times=$(tr '\n' ' ' < /burst)
n=$(wc -l < /burst)
gaps=$(awk 'NR > 1 && $1 - p < 3 { bad++ } { p = $1 } END { print bad + 0 }' /burst)
[ "$n" = 3 ] && [ "$gaps" = 0 ] && ok "three RAs after SIGHUP at ${times}" ||
	nok "RAs after SIGHUP at: ${times}"
kill "$u"
echo "--- ${fails} failure(s)"
[ "${fails}" = 0 ]
INNER
