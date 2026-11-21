#!/usr/bin/env bash
# End-to-end tests with the Android client. Run ./lab.sh [-e ENV] android test.
# ANDROID_TARGETS: space-separated tests, from env.conf:
#   4:ADDR   ping over IPv4      6:ADDR   ping over IPv6
#   dns:NAME ping a name (the lab DNS must resolve it)
# Usage: android/test.sh [--results DIR]
# shellcheck disable=SC2024  # the log file belongs to the user
set -u
cd "$(dirname "$0")/.." || exit 1
node="clab-android-e2e-android"
results=results
[ "${1:-}" = "--results" ] && results="${2:?--results needs a directory}"
mkdir -p "${results}"
log="${results}/android-tests.txt"
: > "${log}"
failed=0
targets="${ANDROID_TARGETS:-4:203.0.113.42 6:2001:db8:cafe::1}"

adb() {
	sudo docker exec "${node}" /sdk/platform-tools/adb -s emulator-5554 "$@"
}

for ((i = 0; i < 60; i++)); do
	sudo docker exec "${node}" test -e /run/android-ready && break
	sleep 10
done
if ! sudo docker exec "${node}" test -e /run/android-ready; then
	echo "FAIL android-boot" | tee -a "${log}"
	sudo docker logs --tail 50 "${node}" >> "${log}" 2>&1
	exit 1
fi
echo "PASS android-boot" | tee -a "${log}"

# Wait for a global IPv6 address on Wi-Fi (RA from the AP).
for ((i = 0; i < 30; i++)); do
	adb shell ip -6 addr show dev wlan0 scope global | grep -q inet6 && break
	sleep 10
done
adb shell 'ip addr show dev wlan0; ip addr show | grep -A3 v4-; ip -6 route; getprop | grep dns' >> "${log}" 2>&1

for t in ${targets}; do
	kind="${t%%:*}" addr="${t#*:}"
	case "${kind}" in
	4) cmd="ping -c 3 -W 2 ${addr}" ;;
	6) cmd="ping6 -c 3 -W 2 ${addr}" ;;
	dns) cmd="ping6 -c 3 -W 2 ${addr} || ping -c 3 -W 2 ${addr}" ;;
	*) echo "unknown test ${t}" >&2; failed=1; continue ;;
	esac
	ok=0
	for ((i = 0; i < 6; i++)); do
		if adb shell "${cmd}" >> "${log}" 2>&1; then ok=1; break; fi
		sleep 10
	done
	if [ "${ok}" = 1 ]; then
		echo "PASS android-${kind}-${addr}" | tee -a "${log}"
	else
		echo "FAIL android-${kind}-${addr}" | tee -a "${log}"
		failed=1
	fi
done
exit "${failed}"
