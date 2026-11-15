#!/bin/bash
# Runs inside a lab client (or the server) and records what the client sees
# during a failover. common.sh copies it in with "bash -c".
#
#   start <dir>            outbound: ping6 from the site A address and from
#                          the site B address, and ping4, every 100 ms; one
#                          long TCP stream for IPv6 and IPv4; curl every 1 s
#                          for IPv6 and IPv4. ping binds its source address,
#                          so there is one ping6 for each prefix.
#   start <dir> <address>  inbound: ping6 to <address> every 100 ms.
#   stop <dir>             stop all probes of <dir>.
#
# Each line has the time from $EPOCHREALTIME. The clients share the clock of
# the lab host, so outage.py compares them with the time of the cut.
S6=2001:db8:cafe:1::2
S4=203.0.113.66
PORT=8081
cmd=$1 d=$2

stream() { # stream <4|6> <socat address>
	# The first line from the server is the source address of the stream.
	socat -u "$2" STDOUT 2> "$d/tcp$1.err" | {
		read -r src && echo "$src" > "$d/tcp$1.src"
		while read -r _; do echo "$EPOCHREALTIME"; done > "$d/tcp$1"
	}
	echo "closed $EPOCHREALTIME" >> "$d/tcp$1.state"
}

connect() { # connect <4|6> <url>
	while :; do
		t=$EPOCHREALTIME
		{ curl -s -o /dev/null -m 3 "$2" && r=ok || r=fail; echo "$t $r $EPOCHREALTIME"; } >> "$d/curl$1" &
		sleep 1
	done
}

case "$cmd" in
start)
	rm -rf "$d"
	mkdir -p "$d"
	echo "$EPOCHREALTIME" > "$d/start"
	# The probes get their own process group, so "stop" can end all of them.
	set -m
	(
		if [ -n "${3:-}" ]; then
			ping -6 -n -D -O -i 0.1 -W 1 "$3" > "$d/ping6" 2>&1 &
		else
			for p in a b; do
				src=$(ip -6 -o addr show dev lan scope global -deprecated |
					awk -v p="2001:db8:$p:" '$4 ~ "^"p {sub("/.*", "", $4); print $4; exit}')
				[ -n "$src" ] && ping -6 -n -D -O -i 0.1 -W 1 -I "$src" "$S6" > "$d/ping6$p" 2>&1 &
			done
			ping -4 -n -D -O -i 0.1 -W 1 "$S4" > "$d/ping4" 2>&1 &
			stream 6 "TCP6:[$S6]:$PORT" &
			stream 4 "TCP4:$S4:$PORT" &
			connect 6 "http://[$S6]:8080/" &
			connect 4 "http://$S4:8080/" &
		fi
		wait
	) < /dev/null > /dev/null 2>&1 &
	echo $! > "$d/pid"
	;;
stop)
	echo "$EPOCHREALTIME" > "$d/stop"
	# A stream that still runs at the stop survived the failover.
	for v in 4 6; do
		[ -e "$d/tcp$v" ] && ! grep -qs closed "$d/tcp$v.state" && echo "open $EPOCHREALTIME" >> "$d/tcp$v.state"
	done
	kill -TERM -- "-$(cat "$d/pid")" 2>/dev/null
	sleep 0.5
	;;
esac
exit 0
