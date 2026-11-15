#!/bin/sh
# Client traffic monitor for the multi-PoP tests. It runs in a client
# container and measures the outage as the client sees it.
#   clientmon.sh start <target6> <target4>   start the monitors in /tmp/mon
#   clientmon.sh stop                        stop them and print the logs
# Per address family (6 and 4):
#   ping<f>.log   ping every 100 ms. A new ping starts every 1 s, so the
#                 kernel selects the source address again (as a new app does).
#   tcp<f>.log    one long-lived TCP stream (port 9000). The server sends a
#                 line every 100 ms; each line gets the receive time. "END"
#                 means the stream closed (or had no data for 3 s); then a
#                 new stream starts.
#   curl<f>.log   one new HTTP connection (port 8081) every 1 s: "<time> ok|fail".
# All times are epoch seconds with fractions (the host clock).
D=/tmp/mon

now() { date +%s.%N; }

pinger() { # family target
	while :; do
		t=$(date +%s)
		ping "-$1" -D -n -i 0.1 -c 10 -W 1 "$2" 2>&1
		# No route: ping stops at once. Do not spin.
		[ "$(date +%s)" -gt "$t" ] || sleep 0.5
	done > "$D/ping$1.log"
}

stream() { # family host
	# A stream from a dead source stalls and does not close. socat -T 3
	# closes it after 3 s with no data, and a new stream starts at once,
	# as an app with a keepalive does.
	while [ ! -e "$D/stop" ]; do
		socat -u -T 3 "TCP$1:$2:9000" STDOUT 2>&1
		echo "END rc=$?"
		sleep 0.2
	done |
		while IFS= read -r l; do echo "$(now) $l"; done > "$D/tcp$1.log"
}

newconn() { # family url
	while :; do
		t=$(now)
		if curl "-$1" -s -m 1 -o /dev/null "$2"; then r=ok; else r=fail; fi
		echo "$t $r"
		sleep 1
	done > "$D/curl$1.log"
}

case "$1" in
start)
	rm -rf "$D" && mkdir -p "$D"
	now > "$D/start"
	pinger 6 "$2" & echo $! >> "$D/pids"
	pinger 4 "$3" & echo $! >> "$D/pids"
	stream 6 "[$2]" & echo $! >> "$D/pids"
	stream 4 "$3" & echo $! >> "$D/pids"
	newconn 6 "http://[$2]:8081/" & echo $! >> "$D/pids"
	newconn 4 "http://$3:8081/" & echo $! >> "$D/pids"
	wait
	;;
stop)
	now > "$D/stop"
	while read -r p; do kill "$p" 2>/dev/null; done < "$D/pids"
	pkill -f "socat -u -T 3 TCP" 2>/dev/null
	sleep 2
	pkill -f "ping -[46] -D" 2>/dev/null
	for f in start stop ping6.log ping4.log tcp6.log tcp4.log curl6.log curl4.log; do
		echo "=== $f"
		cat "$D/$f" 2>/dev/null
	done
	;;
esac
