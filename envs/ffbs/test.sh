#!/usr/bin/env bash
# Tests of the ffbs environment on the running lab.
# Usage: envs/ffbs/test.sh [--results DIR]   (./lab.sh -e ffbs test)
#
# 1. etcd has the default node configuration (lab-etcd-init on concentrator1).
# 2. Each AP has a WireGuard handshake with a concentrator.
# 3. Each client reaches the internet test targets over IPv4 and IPv6, through
#    the concentrators, the backbone and exit1.

# shellcheck disable=SC2329  # the check functions run through check()
set -u
cd "$(dirname "$0")/../.." || exit 1
LAB="${LAB:-ffbs-lab}"
export LAB GATEWAY_USER="${GATEWAY_USER:-debian}" GATEWAY_PASS="${GATEWAY_PASS:-ffmuc}"
results=results
[ "${1:-}" = "--results" ] && results="${2:?--results needs a directory}"
mkdir -p "${results}"
log="${results}/ffbs-tests.txt"
: > "${log}"
failed=0

# check NAME TRIES CMD...: run CMD until it succeeds, 10 s between tries.
check() {
	local name="$1" tries="$2" i
	shift 2
	for ((i = 1; i <= tries; i++)); do
		if "$@" >> "${log}" 2>&1; then
			echo "PASS ${name}" | tee -a "${log}"
			return 0
		fi
		sleep 10
	done
	echo "FAIL ${name}" | tee -a "${log}"
	failed=1
}

etcd_ready() {
	./node-cmd.sh concentrator1 \
		'sudo bash -c "source /etc/profile.d/etcd.sh; etcdctl get /config/default/concentrators --print-value-only"' 30 |
		grep -q '"pubkey"'
}

ap_handshake() {
	./node-cmd.sh "$1" 'wg show all latest-handshakes' 20 | grep -qE '[[:space:]][1-9][0-9]{8,}'
}

client_ping() {
	sudo docker exec "clab-${LAB}-$1" ping "$2" -c 3 -W 2 "$3"
}

check etcd-config 60 etcd_ready
for ap in ap-1 ap-2; do
	check "${ap}-wireguard" 60 ap_handshake "${ap}"
done
for c in client-1 client-2 client-3; do
	check "${c}-ipv4" 30 client_ping "${c}" -4 203.0.113.42
	check "${c}-ipv6" 30 client_ping "${c}" -6 2001:db8:cafe::1
done

exit "${failed}"
