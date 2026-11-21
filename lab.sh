#!/usr/bin/env bash
# One entry point for all lab environments (envs/*/env.conf).
#
# Usage: ./lab.sh [-e ENV] COMMAND [ARGS]
#   list              show the environments
#   info              show the settings of ENV
#   build             build the images (./build.sh)
#   deploy            make the host bridges and start the lab
#   destroy           stop the lab and remove it
#   cmd NODE 'CMD'    run a command on a VM through its serial console
#   test [ARGS]       run the tests of ENV on the running lab
#   run               build, deploy, test and destroy on a fresh host (./run.sh)
#   android up|test|down  Android client on an AP LAN (docs/android-e2e.md)
#
# ENV: -e, else LAB_ENV, else ffmuc. See docs/environments.md.

set -eu

cd "$(dirname "$0")"
# shellcheck source=lib/env.sh
. lib/env.sh

env_name="${LAB_ENV:-ffmuc}"
if [ "${1:-}" = "-e" ]; then
	env_name="${2:?-e needs an environment}"
	shift 2
fi
command="${1:-}"
[ $# -gt 0 ] && shift

usage() {
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

case "${command}" in
list)
	list_envs
	exit 0
	;;
"" | -h | --help | help)
	usage
	;;
esac

load_env "${env_name}"
export LAB_ENV="${ENV_NAME}"

case "${command}" in
info)
	for v in ENV_NAME LAB_NAME TOPOLOGY IMAGE_PREFIX BRIDGES GATEWAYS GATEWAY_NODES \
		GATEWAY_USER PACKER_VARS APS GLUON_IMAGE GLUON_URADVD_PATCH ANDROID_BRIDGE ANDROID_TARGETS; do
		printf '%-19s %s\n' "${v}" "${!v}"
	done
	;;
build)
	./build.sh "${ENV_NAME}"
	;;
deploy)
	sudo ./lab-bridges.sh "${ENV_NAME}"
	vars=$(env_deploy_vars) || exit 1
	# shellcheck disable=SC2086
	sudo env ${vars} containerlab deploy -t "${TOPOLOGY}" --reconfigure
	;;
destroy)
	sudo docker rm -f "${LAB}-monsrv" > /dev/null 2>&1 || true
	sudo containerlab destroy -t "${TOPOLOGY}" --cleanup
	;;
cmd)
	exec ./node-cmd.sh "$@"
	;;
test)
	env_tests "$@"
	;;
run)
	exec ./run.sh "${ENV_NAME}"
	;;
android)
	: "${ANDROID_BRIDGE:?envs/${ENV_NAME}/env.conf sets no ANDROID_BRIDGE}"
	clab=(sudo env "ANDROID_BRIDGE=${ANDROID_BRIDGE}" "ANDROID_API=${ANDROID_API:-35}"
		"ANDROID_TAG=${ANDROID_TAG:-default}" "ANDROID_SDK=${ANDROID_SDK:-sdk}"
		containerlab)
	case "${1:-}" in
	up)
		docker build android -t android-e2e:emulator
		"${clab[@]}" deploy -t android/android.clab.yml --reconfigure
		;;
	test)
		shift
		ANDROID_TARGETS="${ANDROID_TARGETS}" android/test.sh "$@"
		;;
	down)
		"${clab[@]}" destroy -t android/android.clab.yml --cleanup
		;;
	*)
		echo "usage: ./lab.sh [-e ENV] android up|test|down" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "unknown command: ${command}" >&2
	usage 1
	;;
esac
