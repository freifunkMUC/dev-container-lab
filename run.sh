#!/usr/bin/env bash
# Runs the multi-PoP lab (active/active) end to end on a fresh Ubuntu 24.04
# host: installs the tools, builds the images, deploys the lab, runs the
# tests, collects the logs and destroys the lab.
#
# Run it from the repository root as a normal user with sudo. Results go to
# results/: summary.json and the raw logs. Exit code 0 only if all tests pass.
#
# The Gluon firmware comes from FIRMWARE (default: the one *.img.gz in
# multipop/firmware/, or an *.img that is already in gluon/).

# shellcheck disable=SC2024  # the logs belong to the user, not to root
set -uo pipefail
cd "$(dirname "$0")" || exit 1
ROOT=$PWD
export LAB=ffmuc-mp-aa
export RESULTS="${ROOT}/results"
TESTS="${TESTS:-normal ra-single source-prefix rule8-tie pmtu roam pgw-failure broker-kill emqx-kill haproxy-kill broker-down site-failure recovery site-a-failover flapping long-outage old-firmware}"
READY_TIMEOUT="${READY_TIMEOUT:-3600}"
export PATH="${HOME}/.local/bin:${PATH}"
mkdir -p "${RESULTS}"
exec > >(tee -a "${RESULTS}/run.log") 2>&1
command -v jq >/dev/null || { sudo apt-get update -q && sudo apt-get install -y -q jq; } >/dev/null

STAGES=()
stage() { # stage <name> <pass|fail> <detail>
	STAGES+=("$(jq -nc --arg n "$1" --arg s "$2" --arg d "$3" '{test: $n, status: $s, evidence: [$d]}')")
	echo "=== stage $1: $2 - $3"
}

summary() {
	local all=pass t f
	{
		printf '%s\n' "${STAGES[@]}"
		for t in ${TESTS}; do
			f="${RESULTS}/${t}.json"
			if [ -s "${f}" ]; then
				jq -c . "${f}"
			else
				jq -nc --arg n "${t}" '{test: $n, status: "fail", evidence: ["did not run"]}'
			fi
		done
	} | jq -s '{lab: "'"${LAB}"'", variant: "active/active", tests: .}' > "${RESULTS}/summary.json.tmp"
	jq -e 'all(.tests[]; .status == "pass")' "${RESULTS}/summary.json.tmp" >/dev/null || all=fail
	# "downtime": for each failover case, the worst client outage in seconds
	# and the node times (the full numbers are in the metrics of each test).
	jq --arg s "${all}" '. + {status: $s, downtime: ([.tests[].metrics // {} | to_entries[] |
		{(.key): ((.value.downtime_s // {}) + {node: .value.node})}] | add)}' \
		"${RESULTS}/summary.json.tmp" > "${RESULTS}/summary.json"
	rm -f "${RESULTS}/summary.json.tmp"
	echo "=== result: ${all}"
	jq -r '.tests[] | "\(.status)\t\(.test)"' "${RESULTS}/summary.json"
	jq -c '.downtime // {} | to_entries[] | {(.key): .value}' "${RESULTS}/summary.json"
	[ "${all}" = pass ]
}

fail_early() {
	stage "$1" fail "$2"
	summary
	exit 1
}

# 1. Nested KVM is needed for the gateway and AP VMs.
if [ ! -c /dev/kvm ]; then
	fail_early kvm "/dev/kvm is missing: this host has no (nested) KVM"
fi
stage kvm pass "/dev/kvm present; $(nproc) CPUs, $(free -g | awk '/Mem:/ {print $2}') GiB RAM"

# 2. Tools. Only https downloads.
install_tools() {
	export DEBIAN_FRONTEND=noninteractive
	sudo -E apt-get update -q
	sudo -E apt-get install -y -q docker.io docker-buildx jq curl gpg lsb-release patch \
		qemu-system-x86 qemu-utils sshpass pipx signify-openbsd wireguard-tools \
		xorriso openssh-client ncurses-bin
	sudo chmod 666 /dev/kvm /var/run/docker.sock
	command -v containerlab >/dev/null ||
		bash -c "$(curl -sL https://get.containerlab.dev)"
	if ! command -v packer >/dev/null; then
		curl -fsSL https://apt.releases.hashicorp.com/gpg |
			sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
		echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" |
			sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
		sudo -E apt-get update -q && sudo -E apt-get install -y -q packer
	fi
	command -v ansible-playbook >/dev/null || pipx install --include-deps ansible
	ansible-galaxy collection install ansible.posix
	packer plugins install github.com/hashicorp/ansible
	packer plugins install github.com/hashicorp/qemu
}
install_tools > "${RESULTS}/install.log" 2>&1 ||
	fail_early install "tool installation failed, see install.log"
stage install pass "$(docker --version); $(containerlab version 2>/dev/null | awk '/version:/ {print "containerlab " $2}'); $(packer version | head -1); $(ansible --version | head -1)"

# 3. Firmware and images.
if ! ls gluon/gluon-ffmuc-*-x86-64*.img >/dev/null 2>&1; then
	fw="${FIRMWARE:-$(ls multipop/firmware/*.img.gz 2>/dev/null | head -1)}"
	[ -n "${fw}" ] || fail_early firmware "no Gluon firmware: put an x86-64 factory *.img.gz in multipop/firmware/"
	img="gluon/$(basename "${fw}" .gz)"
	# Gluon/OpenWrt images have fwtool metadata and a signature after the
	# gzip data. gunzip then says "trailing garbage ignored" and exits with 2.
	rc=0
	gunzip -c "${fw}" > "${img}" 2> "${RESULTS}/firmware.log" || rc=$?
	if [ "${rc}" -gt 2 ] || [ ! -s "${img}" ]; then
		rm -f "${img}"
		fail_early firmware "cannot unpack ${fw} (gunzip exit ${rc}), see firmware.log"
	fi
fi
stage firmware pass "$(ls gluon/gluon-ffmuc-*-x86-64*.img), $(stat -c %s gluon/gluon-ffmuc-*-x86-64*.img) bytes"

start=${SECONDS}
TERM=dumb ./build.sh < /dev/null > "${RESULTS}/build.log" 2>&1
images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -c '^ffmuc-lab:')
disks=$(ls gateway/parker-gw0[1-4].qcow2 2>/dev/null | wc -l)
[ "${images}" -ge 6 ] && [ "${disks}" = 4 ] ||
	fail_early build "build failed (${images} of 6 images, ${disks} of 4 gateway disks), see build.log"
# The build cache is not needed any more.
docker builder prune -af >/dev/null 2>&1 || true
stage build pass "6 images and 4 gateway disks in $((SECONDS - start)) s, disk: $(df -h --output=used,avail / | tail -1)"

# 4. Deploy and wait until both APs have both sites up.
cleanup() {
	echo "=== collecting logs"
	"${ROOT}/multipop/collect-logs.sh" > "${RESULTS}/collect.log" 2>&1
	sudo containerlab destroy -t ffmuc.clab.yml --cleanup > "${RESULTS}/destroy.log" 2>&1
}
sudo ./lab-bridges.sh
if ! sudo containerlab deploy -t ffmuc.clab.yml > "${RESULTS}/deploy.log" 2>&1; then
	cleanup
	fail_early deploy "containerlab deploy failed, see deploy.log"
fi
trap cleanup EXIT

# renew_lease <client>: a client can keep a 192.168.1.x lease from the
# setup mode of the node for a long time. Release it, remove the old IPv4
# address, routes and lease, and start the DHCP client again (the same way
# as client/entrypoint.sh).
renew_lease() {
	sudo docker exec "clab-${LAB}-$1" sh -c '
		dhcpcd -k lan >/dev/null 2>&1; sleep 1
		ip -4 addr flush dev lan scope global; ip -4 route flush dev lan
		rm -f /var/lib/dhcpcd/*lan*
		if [ "${IPV6_CLIENT:-kernel}" = dhcpcd ]; then dhcpcd -t 0 -b lan; else dhcpcd -4 -t 0 -b lan; fi
	' > /dev/null 2>&1
}
declare -A renewed
start=${SECONDS}
ready=0
while [ $((SECONDS - start)) -lt "${READY_TIMEOUT}" ]; do
	ok=0
	for ap in ap-1 ap-2; do
		st=$(./node-cmd.sh "${ap}" 'cat /tmp/multipop/status 2>/dev/null' 2>/dev/null)
		echo "${st}" | grep -q 'muc01 up' && echo "${st}" | grep -q 'vie01 up' && ok=$((ok + 1))
	done
	clients=0
	for c in client-1 client-2 client-3 client-4; do
		a=$(sudo docker exec "clab-${LAB}-${c}" ip -6 -o addr show dev lan scope global 2>/dev/null)
		# The IPv4 tests need a DHCPv4 lease from the node (10.0.4.0/22), not
		# the IPv4LL address that dhcpcd uses until then.
		a4=$(sudo docker exec "clab-${LAB}-${c}" ip -4 -o addr show dev lan scope global 2>/dev/null)
		echo "${a}" | grep -q '2001:db8:a:' && echo "${a}" | grep -q '2001:db8:b:' &&
			echo "${a4}" | grep -q ' 10\.0\.' && clients=$((clients + 1))
		# Only a lease from the node in normal mode (10/8) counts. When both
		# nodes are up and a client has another IPv4 address (also next to a
		# 10/8 one), renew the lease at once, then at most every 120 s.
		if [ "${ok}" = 2 ] && echo "${a4}" | grep ' inet ' | grep -vq ' inet 10\.' &&
			[ $((SECONDS - ${renewed[$c]:--999})) -ge 120 ]; then
			echo "[$(date +%T)] ${c}: no 10/8 lease ($(echo "${a4}" | awk '{print $4}' | tr '\n' ' ')), renewing it"
			renew_lease "${c}"
			renewed[$c]=${SECONDS}
		fi
	done
	echo "[$(date +%T)] waiting: ${ok}/2 APs with both sites up, ${clients}/4 clients with both prefixes and a DHCPv4 lease"
	if [ "${ok}" = 2 ] && [ "${clients}" = 4 ]; then
		ready=1
		break
	fi
	sleep 30
done
[ "${ready}" = 1 ] || fail_early ready "lab not ready after ${READY_TIMEOUT} s"
stage ready pass "both APs have both sites up and all clients have both prefixes and a DHCPv4 lease after $((SECONDS - start)) s"

# 5. Tests, in this order: failure needs normal, recovery needs failure.
for t in ${TESTS}; do
	echo "=== test ${t}"
	TEST="${t}" "multipop/tests/${t}.sh" || true
done

trap - EXIT
cleanup
summary
