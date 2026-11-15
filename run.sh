#!/usr/bin/env bash
# Build, deploy and test the multi-PoP active/standby lab on one fresh
# Ubuntu 24.04 x86-64 machine, then destroy it.
#
# Run it from the repository (or bundle) root as a normal user with sudo.
# It writes results/summary.json and the raw logs to results/.
# Exit code 0 only if all setup steps and all tests pass.
#
# Needs: nested KVM (/dev/kvm), about 8 vCPU, 32 GB RAM, 40 GB free disk,
# outbound HTTPS. Gluon image: gluon/*.img, or artifacts/*.img.gz (unpacked
# here), or GLUON_IMAGE_URL (downloaded over HTTPS).

set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT=$(pwd)
RESULTS="${RESULTS:-${ROOT}/results}"
LAB=ffmuc-mp-as
mkdir -p "${RESULTS}"
STEPS="${RESULTS}/steps.tsv"
: > "${STEPS}"
exec > >(tee -a "${RESULTS}/run.log") 2>&1

DEPLOYED=0
FAILED=0

log() { echo "=== $(date -u +%FT%TZ) $*"; }

# step <name> <command...>: runs the command, logs to results/step-<name>.log,
# and records the status. Later steps do not run after a failure.
step() {
	local name="$1"
	shift
	if [ "${FAILED}" = 1 ]; then
		printf '%s\tskipped\t0\n' "${name}" >> "${STEPS}"
		return 1
	fi
	log "step ${name}: start"
	local t0 rc
	t0=$(date +%s)
	"$@" > >(tee "${RESULTS}/step-${name}.log") 2>&1
	rc=$?
	printf '%s\t%s\t%s\n' "${name}" "$([ "${rc}" = 0 ] && echo pass || echo "fail(rc=${rc})")" \
		"$(( $(date +%s) - t0 ))" >> "${STEPS}"
	log "step ${name}: rc=${rc}"
	[ "${rc}" = 0 ] || FAILED=1
	return "${rc}"
}

check_kvm() {
	[ "$(uname -m)" = x86_64 ] || { echo "needs x86_64, have $(uname -m)"; return 1; }
	sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
	if [ ! -c /dev/kvm ]; then
		echo "/dev/kvm is missing: no nested virtualization on this VM"
		grep -c -E 'vmx|svm' /proc/cpuinfo || true
		return 1
	fi
	sudo chmod 666 /dev/kvm
	df -h "${ROOT}" /var/lib 2>/dev/null
	free -g
	nproc
}

install_deps() {
	export DEBIAN_FRONTEND=noninteractive
	sudo -E apt-get update -q
	sudo -E apt-get install -yq ca-certificates curl gnupg lsb-release python3 \
		qemu-system-x86 qemu-utils wireguard-tools sshpass signify-openbsd \
		ansible docker.io bridge-utils iptables
	sudo systemctl enable --now docker
	if ! command -v containerlab >/dev/null; then
		curl -fsSL https://get.containerlab.dev | sudo -E bash
	fi
	if ! command -v packer >/dev/null; then
		curl -fsSL https://apt.releases.hashicorp.com/gpg |
			sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
		echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" |
			sudo tee /etc/apt/sources.list.d/hashicorp.list
		sudo -E apt-get update -q
		sudo -E apt-get install -yq packer
	fi
	sudo ansible-galaxy collection install ansible.posix
	containerlab version
	packer version
	ansible --version | head -1
	docker --version
}

gluon_image() {
	if ls gluon/*.img >/dev/null 2>&1; then
		ls -l gluon/*.img
		return 0
	fi
	local gz
	gz=$(ls artifacts/*x86-64*.img.gz 2>/dev/null | head -1)
	if [ -z "${gz}" ] && [ -n "${GLUON_IMAGE_URL:-}" ]; then
		gz="artifacts/$(basename "${GLUON_IMAGE_URL}")"
		mkdir -p artifacts
		curl -fsSL -o "${gz}" "${GLUON_IMAGE_URL}"
	fi
	[ -n "${gz}" ] || { echo "no Gluon image: put one in artifacts/ or set GLUON_IMAGE_URL"; return 1; }
	# gunzip returns 2 on "trailing garbage" from the Gluon signature.
	gunzip -c "${gz}" > "gluon/$(basename "${gz%.gz}")" || [ $? = 2 ]
	ls -l gluon/*.img
}

build_images() {
	# Headless packer, and no "reset" on a missing terminal.
	sudo -E env TERM=dumb PACKER_ARGS="-var headless=true" PATH="${PATH}" \
		./build.sh < /dev/null
	ls -l gateway/*.qcow2
	# The images now hold the qcow2s; free the disk.
	sudo rm -f gateway/*.qcow2
	sudo docker builder prune -af >/dev/null
	sudo docker images
	df -h "${ROOT}" /var/lib
}

deploy() {
	sudo ./lab-bridges.sh
	DEPLOYED=1
	sudo containerlab deploy -t ffmuc.clab.yml --reconfigure
}

run_tests() {
	python3 tests/multipop_as.py --results "${RESULTS}"
}

collect_logs() {
	local d="${RESULTS}/logs"
	mkdir -p "${d}"
	sudo containerlab inspect -t ffmuc.clab.yml > "${d}/inspect.txt" 2>&1
	for c in $(sudo docker ps -a --format '{{.Names}}' | grep "^clab-${LAB}-"); do
		sudo docker logs "${c}" > "${d}/${c#clab-${LAB}-}.docker.log" 2>&1
	done
	for ap in ap-1 ap-2; do
		timeout 120 ./node-cmd.sh "${ap}" 'cat /tmp/parker-as/status; for f in /tmp/parker-as/radvd.*; do echo "$f: $(cat $f)"; done; ip -6 rule; ip -6 route show table all | grep -v "^local\|^multicast\|fe80"; ip route; nft list table inet parker_as; wg show all; cat /tmp/ff-Ohb0ba0u/noderoute.json; ps w | grep -E "uradvd|clat|parker"; logread | tail -300' 60 \
			> "${d}/${ap}.state.txt" 2>&1
	done
	for gw in gw01 gw02 gw03 gw04; do
		timeout 120 ./node-cmd.sh "gateway-${gw}" 'sudo vtysh -c "show bgp summary" -c "show ip bgp" -c "show bgp ipv6"; sudo wg show all; ip -6 route | head -50; sudo jool session display --numeric 2>/dev/null | head -20; sudo journalctl -n 300 --no-pager -u "wgkex*" -u unbound -u frr' 60 \
			> "${d}/gateway-${gw}.state.txt" 2>&1
	done
	sudo docker exec "clab-${LAB}-internet" vtysh -c 'show bgp summary' -c 'show ip bgp' -c 'show bgp ipv6' \
		> "${d}/internet.bgp.txt" 2>&1
}

write_summary() {
	python3 - "${RESULTS}" "${STEPS}" <<'EOF'
import glob, json, os, sys
results, steps_file = sys.argv[1], sys.argv[2]
steps = []
for line in open(steps_file):
    name, status, secs = line.rstrip("\n").split("\t")
    steps.append({"name": name, "status": status, "seconds": int(secs)})
tests = []
for f in sorted(glob.glob(os.path.join(results, "test-*.json"))):
    try:
        tests.append(json.load(open(f)))
    except Exception as e:
        tests.append({"name": os.path.basename(f), "pass": False, "evidence": f"bad json: {e}"})
ok = bool(tests) and all(s["status"] in ("pass",) for s in steps if s["name"] != "collect-logs") \
    and all(t.get("pass") for t in tests)
summary = {
    "lab": "ffmuc-mp-as (multi-PoP active/standby)",
    "pass": ok,
    "steps": steps,
    "tests": [{"name": t.get("name"), "pass": t.get("pass"), "evidence": t.get("evidence")} for t in tests],
}
json.dump(summary, open(os.path.join(results, "summary.json"), "w"), indent=2)
print(json.dumps({"pass": ok, "tests": {t.get("name"): t.get("pass") for t in tests},
                  "steps": {s["name"]: s["status"] for s in steps}}, indent=2))
sys.exit(0 if ok else 1)
EOF
}

finish() {
	trap - EXIT
	if [ "${DEPLOYED}" = 1 ]; then
		FAILED=0
		step collect-logs collect_logs || true
		log "destroy"
		sudo containerlab destroy -t ffmuc.clab.yml --cleanup > "${RESULTS}/destroy.log" 2>&1
	fi
	sudo chown -R "$(id -u):$(id -g)" "${RESULTS}" 2>/dev/null
	write_summary
	exit $?
}
trap finish EXIT

step check-kvm check_kvm
step install install_deps
step gluon-image gluon_image
step build build_images
step deploy deploy
step tests run_tests
