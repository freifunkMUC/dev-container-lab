#!/usr/bin/env bash
# Shared helpers for the multi-PoP lab tests. Source this file.
# Each test writes results/<test>.json: {"test", "status", "evidence"}.
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
	printf '%s\n' "${EVIDENCE[@]}" | jq -R . | jq -s \
		--arg t "${TEST}" --arg s "${status}" '{test: $t, status: $s, evidence: .}' \
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
