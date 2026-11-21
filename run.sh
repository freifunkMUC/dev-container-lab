#!/usr/bin/env bash
# Redirects write user-owned result files on purpose (SC2024); AP commands run remotely (SC2016).
# shellcheck disable=SC2024,SC2016,SC2012
# Build, deploy and test one lab environment on one fresh Ubuntu 24.04
# x86-64 machine, then destroy it.
#
# Usage: ./run.sh [ENV]   (default: LAB_ENV, else ffmuc; see envs/)
# Run it from the repository (or bundle) root as a normal user with sudo.
# It writes results/summary.json and the raw logs to results/.
# Exit code 0 only if all setup steps and all tests pass.
#
# Needs: nested KVM (/dev/kvm), about 8 vCPU, 16 GB RAM, a 128 GB disk,
# outbound HTTPS. Gluon image: GLUON_IMAGE of the environment (a file in
# gluon/), or artifacts/*.img.gz (unpacked here), or GLUON_IMAGE_URL
# (downloaded over HTTPS).

set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT=$(pwd)
RESULTS="${RESULTS:-${ROOT}/results}"
# shellcheck source=lib/env.sh
. lib/env.sh
load_env "${1:-}" || exit 1
export LAB_ENV="${ENV_NAME}"
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
		ansible docker.io docker-buildx bridge-utils iptables xorriso patch rsync openssl
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
	xorriso -version 2>&1 | head -1
	ansible --version | head -1
	docker --version
	docker buildx version
}

gluon_image() {
	local image
	image=$(fetch_gluon) || return 1
	ls -l "gluon/${image}"
}

build_images() {
	# Headless packer, and no "reset" on a missing terminal.
	sudo -E env TERM=dumb PACKER_ARGS="-var headless=true" PATH="${PATH}" \
		./build.sh "${ENV_NAME}" < /dev/null
	# The gateways bind their disks at run time: keep them. Free the
	# packer download cache and the build cache.
	local gw
	for gw in ${GATEWAYS}; do
		du -sh "${GATEWAY_DIR}/${gw}.qcow2"
	done
	sudo rm -rf gateway/packer/packer_cache
	sudo docker builder prune -af >/dev/null
	sudo docker images
	df -h "${ROOT}" /var/lib
}

deploy() {
	sudo ./lab-bridges.sh "${ENV_NAME}"
	DEPLOYED=1
	local vars
	vars=$(env_deploy_vars) || return 1
	# shellcheck disable=SC2086
	sudo env ${vars} containerlab deploy -t "${TOPOLOGY}" --reconfigure
}

run_tests() {
	env_tests --results "${RESULTS}"
}

collect_logs() {
	local d="${RESULTS}/logs"
	mkdir -p "${d}"
	sudo containerlab inspect -t "${TOPOLOGY}" > "${d}/inspect.txt" 2>&1
	for c in $(sudo docker ps -a --format '{{.Names}}' | grep "^clab-${LAB}-"); do
		sudo docker logs "${c}" > "${d}/${c#clab-"${LAB}"-}.docker.log" 2>&1
	done
	env_collect_logs "${d}"
}

write_summary() {
	python3 - "${RESULTS}" "${STEPS}" "${ENV_NAME}" "${LAB}" <<'EOF'
import glob, json, os, sys
results, steps_file, env, lab = sys.argv[1:5]
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
    "lab": lab,
    "env": env,
    "pass": ok,
    "steps": steps,
    "tests": [{"name": t.get("name"), "pass": t.get("pass"), "evidence": t.get("evidence"),
               "metrics": t.get("metrics", {})} for t in tests],
    # Downtime per case: "ap" in s (AP status), "clients" per client
    # (longest gap in ms, lost pings, TCP stream survived, new connection in s).
    "downtime": {t.get("name"): t["metrics"] for t in tests if t.get("metrics")},
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
		sudo docker rm -f "${LAB}-monsrv" > /dev/null 2>&1
		sudo containerlab destroy -t "${TOPOLOGY}" --cleanup > "${RESULTS}/destroy.log" 2>&1
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
