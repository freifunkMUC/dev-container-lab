# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are used by the scripts that source this
# Load a lab environment. Source this file, then call load_env NAME.
#
# An environment is a directory envs/NAME/ with an env.conf file. env.conf is
# shell: it sets the variables below and can define the hook functions. Paths
# are relative to the repository root. See docs/environments.md.

LAB_ROOT="${LAB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Defaults for all environments. An env.conf sets what differs.
env_defaults() {
	LAB_NAME=""                # containerlab "name:" in TOPOLOGY
	TOPOLOGY=""                # containerlab topology file
	IMAGE_PREFIX="ffmuc-lab"   # docker image tags: IMAGE_PREFIX:gluon etc.
	BRIDGES=""                 # host bridges the topology uses (lab-bridges.sh)
	GATEWAYS=""                # gateway VM names; disks are GATEWAY_DIR/NAME.qcow2
	GATEWAY_DIR="gateway"
	GATEWAY_NODES=""           # containerlab nodes of the gateways
	GATEWAY_USER="ubuntu"      # serial console login of the gateways
	GATEWAY_PASS="ffmuc"
	# Packer variable file, relative to gateway/packer/. It selects the base
	# image and the Ansible playbooks that provision the gateways.
	PACKER_VARS=""
	APS=""                     # containerlab nodes of the APs
	# Gluon image: a file name glob in gluon/, a path, or an https URL of an
	# .img or .img.gz file. GLUON_IMAGE_URL overrides it.
	GLUON_IMAGE="gluon-*-x86-64*.img"
	GLUON_URADVD_PATCH=""      # patch for the uradvd in the AP image (optional)
	# Android end-to-end test (docs/android-e2e.md): the AP LAN bridge of the
	# Android node, and the tests (4:ADDR, 6:ADDR, dns:NAME).
	ANDROID_BRIDGE=""
	ANDROID_TARGETS="4:203.0.113.42 6:2001:db8:cafe::1"
}

# Hooks. An env.conf can define them again.
env_prepare() { :; }          # before the gateway build: stage sources, make keys
env_build_extra() { :; }      # after the gateway build: more images
env_deploy_vars() { :; }      # prints VAR=VALUE lines for the topology
env_collect_logs() { :; }     # $1: log directory
env_tests() {                 # "$@": --results DIR
	echo "environment ${ENV_NAME} has no tests" >&2
	return 1
}

load_env() {
	local name="${1:-${LAB_ENV:-ffmuc}}"
	local dir="${LAB_ROOT}/envs/${name}"
	if [ ! -f "${dir}/env.conf" ]; then
		echo "no environment '${name}': envs/${name}/env.conf is missing" >&2
		echo "environments: $(list_envs | tr '\n' ' ')" >&2
		return 1
	fi
	env_defaults
	ENV_NAME="${name}"
	ENV_DIR="envs/${name}"
	# shellcheck source=/dev/null
	. "${dir}/env.conf"
	: "${LAB_NAME:?envs/${name}/env.conf must set LAB_NAME}"
	: "${TOPOLOGY:?envs/${name}/env.conf must set TOPOLOGY}"
	export ENV_NAME ENV_DIR LAB_NAME TOPOLOGY IMAGE_PREFIX GATEWAY_USER GATEWAY_PASS
	# node-cmd.sh and the tests find the containers by LAB.
	export LAB="${LAB_NAME}"
}

list_envs() {
	local f
	for f in "${LAB_ROOT}"/envs/*/env.conf; do
		[ -f "${f}" ] || continue
		basename "$(dirname "${f}")"
	done
}

# Put the Gluon image of the environment into gluon/ and print its file name.
# GLUON_IMAGE_URL, then GLUON_IMAGE (glob in gluon/, path, or URL), then
# artifacts/*x86-64*.img.gz.
fetch_gluon() {
	local src="${GLUON_IMAGE_URL:-${GLUON_IMAGE}}" f
	case "${src}" in
	https://*)
		mkdir -p "${LAB_ROOT}/artifacts"
		f="${LAB_ROOT}/artifacts/$(basename "${src}")"
		[ -s "${f}" ] || curl -fsSL -o "${f}" "${src}" || return 1
		;;
	*/*)
		f="${src}"
		[ -f "${f}" ] || { echo "no Gluon image at ${f}" >&2; return 1; }
		;;
	*)
		# A glob in gluon/. The first match wins.
		for f in "${LAB_ROOT}"/gluon/${src}; do
			[ -f "${f}" ] && { basename "${f}"; return 0; }
		done
		for f in "${LAB_ROOT}"/artifacts/*x86-64*.img.gz; do
			[ -f "${f}" ] && break
		done
		if [ ! -f "${f}" ]; then
			echo "no Gluon image: put one matching gluon/${src} or artifacts/*x86-64*.img.gz," >&2
			echo "or set GLUON_IMAGE_URL" >&2
			return 1
		fi
		;;
	esac
	case "${f}" in
	*.gz)
		local out
		out="${LAB_ROOT}/gluon/$(basename "${f%.gz}")"
		# Gluon images have data after the gzip stream: gzip warns about
		# "trailing garbage" and returns 2. The image is good.
		gzip -dcq "${f}" > "${out}" || [ $? = 2 ] || return 1
		basename "${out}"
		;;
	*)
		[ "$(cd "$(dirname "${f}")" && pwd)" = "${LAB_ROOT}/gluon" ] ||
			cp "${f}" "${LAB_ROOT}/gluon/"
		basename "${f}"
		;;
	esac
}
