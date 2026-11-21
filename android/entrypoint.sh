#!/bin/bash
# Start the Android emulator on the lab LAN. The node has no other network:
# the guest can reach only lab targets.
#   lan            link to the AP LAN bridge
#   /sdk           Android SDK from android/fetch-sdk.sh
#   /dev/kvm       needed: the guest is x86_64
#   ANDROID_API    API level of the system image (default 35)
#   ANDROID_TAG    tag of the system image (default "default", AOSP: adb root works)
set -eu
API="${ANDROID_API:-35}"
TAG="${ANDROID_TAG:-default}"
SDK=/sdk
ADB="${SDK}/platform-tools/adb"
PORT=45500
GATE=/run/relay-closed
SYSIMG="system-images/android-${API}/${TAG}/x86_64"

fail() {
	echo "android: $*" >&2
	exec sleep infinity # keep the node for docker logs
}

[ -c /dev/kvm ] || fail "no /dev/kvm. The emulator needs an x86_64 host with KVM."
[ -x "${SDK}/emulator/emulator" ] || fail "no emulator in /sdk. Run android/fetch-sdk.sh."
[ -d "${SDK}/${SYSIMG}" ] || fail "no ${SYSIMG} in /sdk. Run ANDROID_API=${API} android/fetch-sdk.sh."

until [ -e /sys/class/net/lan ]; do sleep 1; done
# The container itself stays off the lab LAN: no addresses on lan.
sysctl -qw "net.ipv6.conf.lan.disable_ipv6=1"
ip link set lan up promisc on

export ANDROID_SDK_ROOT="${SDK}" ANDROID_HOME="${SDK}" ANDROID_AVD_HOME=/avd ANDROID_EMULATOR_HOME=/avd
mkdir -p /avd/lab.avd
printf 'avd.ini.encoding=UTF-8\npath=/avd/lab.avd\ntarget=android-%s\n' "${API}" > /avd/lab.ini
cat > /avd/lab.avd/config.ini <<EOC
AvdId=lab
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=2
hw.ramSize=2048
disk.dataPartition.size=4G
fastboot.forceColdBoot=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.keyboard=yes
hw.lcd.density=320
hw.lcd.height=1280
hw.lcd.width=720
image.sysdir.1=${SYSIMG}/
tag.id=${TAG}
EOC

touch "${GATE}"
python3 /relay.py "${PORT}" lan "${GATE}" &

if [ "${API}" -ge 31 ]; then
	net=(-feature -WiFiPacketStream -wifi-socket "connect=127.0.0.1:${PORT}")
	link="wifi-socket.sh"
else
	net=(-net-socket "connect=127.0.0.1:${PORT}")
	link="net-socket.sh"
fi
"${SDK}/emulator/emulator" -avd lab -no-window -no-audio -no-snapshot -no-boot-anim \
	-no-metrics -port 5554 "${net[@]}" &
emu=$!

"${ADB}" -s emulator-5554 wait-for-device
until [ "$("${ADB}" -s emulator-5554 shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do
	sleep 5
done
"${ADB}" -s emulator-5554 root
sleep 3
"${ADB}" -s emulator-5554 wait-for-device
for f in /guest/*.sh; do
	"${ADB}" -s emulator-5554 push "${f}" /data/local/tmp/
done
"${ADB}" -s emulator-5554 shell sh /data/local/tmp/firewall.sh
"${ADB}" -s emulator-5554 shell sh "/data/local/tmp/${link}"
rm -f "${GATE}"
echo "android: ready (API ${API}, ${link%.sh})"
touch /run/android-ready
wait "${emu}"
