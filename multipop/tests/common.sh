#!/usr/bin/env bash
# Shared helpers for the multi-PoP lab tests. Source this file.
# Each test writes results/<test>.json: {"test", "status", "evidence"} and,
# for the failover tests, "metrics" (see meas_start and meas_stop).
# shellcheck disable=SC2034  # used by the tests that source this file

LAB="${LAB:-ffmuc-mp-aa}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS="${RESULTS:-${ROOT}/results}"
CLIENTS="${CLIENTS:-client-1 client-2 client-3 client-4}"
APS="${APS:-ap-1 ap-2}"
SERVER6="2001:db8:cafe:1::2"
SERVER4="203.0.113.66"
# The DNS64 answer for v4only.test.lab (203.0.113.66).
SERVER4_IN_NAT64="64:ff9b::cb00:7142"
PREFIX_A="2001:db8:a:"
PREFIX_B="2001:db8:b:"
DNS64_A="2001:db8:a::53"
DNS64_B="2001:db8:b::53"
POOL4_A="198.51.100.11 198.51.100.12"
POOL4_B="192.0.2.13 192.0.2.14"
mkdir -p "${RESULTS}"

TEST="${TEST:-$(basename "$0" .sh)}"
LOG="${RESULTS}/${TEST}.log"
EVIDENCE=()
FAILED=0
METRICS="${RESULTS}/${TEST}.metrics.json"
rm -f "${METRICS}"

log() { echo "[$(date +%T)] $*" | tee -a "${LOG}" >&2; }
dx() { local n="$1"; shift; sudo docker exec "clab-${LAB}-${n}" "$@"; }
node() { LAB="${LAB}" "${ROOT}/node-cmd.sh" "$@"; }

# check <description> <ok|fail> [detail]: record one check.
check() {
	local what="$1" res="$2" detail="${3:-}"
	log "${res^^}: ${what} ${detail:+(${detail})}"
	EVIDENCE+=("${res}: ${what}${detail:+ - ${detail}}")
	[ "${res}" = ok ] || FAILED=1
}

finish() {
	local status=pass
	[ "${FAILED}" = 0 ] || status=fail
	[ -s "${METRICS}" ] || echo '{}' > "${METRICS}"
	printf '%s\n' "${EVIDENCE[@]}" | jq -R . | jq -s \
		--arg t "${TEST}" --arg s "${status}" --slurpfile m "${METRICS}" \
		'{test: $t, status: $s, evidence: ., metrics: $m[0]} | if .metrics == {} then del(.metrics) else . end' \
		> "${RESULTS}/${TEST}.json"
	log "${TEST}: ${status}"
	[ "${status}" = pass ]
}

# The global address of a client in a prefix, and whether it is deprecated.
addr_in() { dx "$1" ip -6 -o addr show dev lan scope global | awk -v p="$2" '$4 ~ "^"p {sub("/.*", "", $4); print $4; exit}'; }
deprecated() { dx "$1" ip -6 -o addr show dev lan scope global | grep "inet6 $2/" | grep -q deprecated; }

# The source address the test server sees. Extra arguments go to curl.
# socat puts IPv6 peer addresses in brackets.
echo_src() { dx "$1" curl -s -m 8 "${@:2}" | tr -d '[]\r'; }

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# wait_for <seconds> <command...>: retry every 5 s until the command works.
wait_for() {
	local end=$((SECONDS + $1)); shift
	until "$@" >/dev/null 2>&1; do
		[ "${SECONDS}" -lt "${end}" ] || return 1
		sleep 5
	done
}

site_state() { node "$1" "cat /tmp/multipop/status" | awk -v s="$2" '$2 == s {print $3 " " $5}'; }

# The status line of a site on an AP matches a regular expression.
ap_has() { node "$1" "cat /tmp/multipop/status" | grep "^wg_c[0-9]* $2 " | grep -Eq -- "$3"; }

# Remove the change history and the penalty on all APs, so that the state
# changes of one test do not set the flapping penalty in the next test.
clear_damping() {
	local ap
	for ap in ${APS}; do node "$ap" 'rm -f /tmp/multipop/*.changes /tmp/multipop/*.penalty /tmp/multipop/*.penalties'; done
}

# The /64 of an address.
p64() { echo "$1" | cut -d: -f1-4; }

# Both sites up and preferred on all APs, and a preferred address of each
# site on all clients.
stable() {
	local ap c a
	for ap in ${APS}; do
		ap_has "$ap" muc01 'up .* preferred=300' && ap_has "$ap" vie01 'up .* preferred=300' || return 1
	done
	for c in ${CLIENTS}; do
		a=$(dx "$c" ip -6 -o addr show dev lan scope global | grep -v deprecated)
		echo "$a" | grep -q " ${PREFIX_A}" && echo "$a" | grep -q " ${PREFIX_B}" || return 1
	done
}

# wait_stable <seconds>: wait until stable, and record the result.
wait_stable() {
	local t0=${SECONDS}
	if wait_for "$1" stable; then
		check "lab is stable again" ok "after $((SECONDS - t0)) s"
	else
		check "lab is stable again" fail "$(for ap in ${APS}; do node "$ap" 'cat /tmp/multipop/status'; done | tr '\n' ';')"
	fi
}

# The gateway that a tunnel of an AP uses now, from the WireGuard endpoint.
# The lab CPE answers gwN.lab with 198.51.100.N (site A) or 192.0.2.N (site B).
pgw_gw() { node "$1" "wg show $2 endpoints" | awk '{split($2, a, "[.:]"); print "gw0" a[4]}'; }

# The wg_cX tunnel of a site on an AP.
site_ifc() { node "$1" "cat /tmp/multipop/status" | awk -v s="$2" '$2 == s {print $1}'; }

# metric <jq path> <JSON value>: record a number in the metrics of the test,
# for example: metric '.pgw_switch.node.detection_s' 3
metric() {
	[ -s "${METRICS}" ] || echo '{}' > "${METRICS}"
	jq --argjson v "$2" "$1 = \$v" "${METRICS}" > "${METRICS}.tmp" && mv "${METRICS}.tmp" "${METRICS}"
}

now() { date +%s.%N; }

# Outage as the clients see it. meas_start <case> [<client> <address>]
# starts the probes of outage-client.sh on all clients. With a client and an
# address, the server also pings that address (inbound). meas_event <case>
# records the time of the cut; meas_stop <case> stops the probes, and writes
# for each client the longest gap, the lost packets, whether the TCP streams
# survived, and the time until a new connection works. The case also gets
# "downtime_s" (seconds, the worst client): ipv6_a and ipv6_b (ping from the
# site A and site B address), ipv4, new_conn_ipv6 and new_conn_ipv4 (curl),
# and inbound (the server pings a client address).
OUTAGE_SH="$(cat "${ROOT}/multipop/tests/outage-client.sh")"
declare -A MEAS_EVENT
meas_start() {
	local c
	for c in ${CLIENTS}; do dx "$c" bash -c "${OUTAGE_SH}" - start "/tmp/meas/$1"; done
	[ -n "${3:-}" ] && dx server bash -c "${OUTAGE_SH}" - start "/tmp/meas/$1" "$3" &&
		metric ".\"$1\".inbound_target" "$(jq -n --arg c "$2" --arg a "$3" '{client: $c, address: $a}')"
	MEAS_EVENT[$1]=$(now)
	sleep 2
}
meas_event() { MEAS_EVENT[$1]=$(now); }
meas_stop() {
	local c dir m worst
	dir="${RESULTS}/${TEST}.meas/$1"
	for c in ${CLIENTS} server; do
		dx "$c" test -d "/tmp/meas/$1" 2>/dev/null || continue
		dx "$c" bash -c "${OUTAGE_SH}" - stop "/tmp/meas/$1"
		mkdir -p "${dir}/$c"
		dx "$c" tar -C "/tmp/meas/$1" -c . | tar -C "${dir}/$c" -x
		dx "$c" rm -rf "/tmp/meas/$1"
		m=$(python3 "${ROOT}/multipop/tests/outage.py" "${dir}/$c" "${MEAS_EVENT[$1]}") || m='{"error": "no data"}'
		if [ "$c" = server ]; then
			metric ".\"$1\".inbound" "$m"
		else
			metric ".\"$1\".clients.\"$c\"" "$m"
		fi
	done
	# The worst client; null if a client never got a reply or a connection.
	worst=$(jq --arg k "$1" 'def worst(f): [.clients[] | f] |
			if length == 0 or any(. == null) then null else max / 1000 end;
		.[$k] | {
		ipv6_a: worst(.ping6a.max_gap_ms), ipv6_b: worst(.ping6b.max_gap_ms),
		ipv4: worst(.ping4.max_gap_ms),
		new_conn_ipv6: worst(.curl6.new_conn_ms), new_conn_ipv4: worst(.curl4.new_conn_ms),
		inbound: (if .inbound.ping6 then .inbound.ping6.max_gap_ms / 1000 else null end)}' "${METRICS}")
	metric ".\"$1\".downtime_s" "${worst}"
	log "$1: downtime ${worst//[$'\n' ]/}"
}

# node_event <ap> <event> <tunnel|.> <case>: the first event of mp-node after
# the cut of the case, in seconds after the cut (the node clock has 1 s steps;
# it is corrected with the offset to the host clock). Empty if none.
node_event() {
	local out h0
	h0=$(now)
	out=$(node "$1" "date +%s; cat /tmp/multipop/events" | tr -d '\r')
	echo "${out}" | awk -v h="$(echo "${h0} $(now)" | awk '{printf "%.3f", ($1 + $2) / 2}')" -v e="$2" -v i="$3" -v t0="${MEAS_EVENT[$4]}" '
		NR == 1 { off = h - $1; next }
		$3 == e && (i == "." || $2 == i) && $1 + off >= t0 - 1 { printf "%.0f\n", $1 + off - t0; exit }'
}
