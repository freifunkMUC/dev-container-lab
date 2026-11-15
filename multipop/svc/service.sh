#!/bin/sh
# LAB: entrypoint of the control-plane services (broker, EMQX, haproxy).
# It sets the address of the service LAN, then runs "$@" and starts it again
# when it stops. To simulate a failure, the tests kill the service and keep
# it down until /tmp/down is removed (see svc_kill and svc_restore in
# multipop/tests/common.sh). The container itself stays up, because
# containerlab does not attach the links again after a container restart.
set -u

until [ -e /sys/class/net/eth1 ]; do sleep 0.2; done
ip link set eth1 up
ip addr replace "${ADDR}" dev eth1
ip route replace default via "${GW}"

[ -n "${PRESTART:-}" ] && sh -c "${PRESTART}"

while :; do
	if [ -e /tmp/down ]; then
		sleep 0.2
		continue
	fi
	# setsid: the service gets its own process group, so svc_kill stops
	# all its processes (for example beam.smp below the emqx script).
	setsid "$@" &
	echo $! >/tmp/service.pid
	wait $!
	echo "service.sh: '$*' stopped with $?"
	sleep 0.5
done
