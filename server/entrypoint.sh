#!/bin/bash
# Multi-PoP test server. Echoes the source address of each TCP connection on
# port 8080, so a test can see which prefix or NAT64 address a client used.
# Port 8081 sends one line every 100 ms for as long as the connection stays
# open: the failover tests use it as a long-lived TCP stream.
# Port 8082 sends 256 KiB (full-size TCP segments, DF=1) for the PMTU test.

until [ -e /sys/class/net/eth1 ]; do sleep 1; done

ip addr add 203.0.113.66/30 dev eth1
ip route add default via 203.0.113.65
ip addr add 2001:db8:cafe:1::2/64 dev eth1 nodad
ip -6 route add default via 2001:db8:cafe:1::1

# socat runs these two small scripts for each connection. A SYSTEM: string
# with printf escapes does not work: socat turns the escapes into real
# newlines and sh then fails with exit 127.
# socat gives an IPv6 peer as "[2001:0db8:000a:...]". peer.sh prints the
# short form (2001:db8:a:...), as "ip addr" on the client shows it.
cat > /tmp/peer.sh <<'SH'
#!/bin/sh
a=$(echo "$SOCAT_PEERADDR" | tr -d '[]')
case "$a" in
*:*) perl -MSocket=inet_pton,inet_ntop,AF_INET6 -e 'print inet_ntop(AF_INET6, inet_pton(AF_INET6, $ARGV[0]))' "$a" ;;
*) printf %s "$a" ;;
esac
SH
cat > /tmp/echo.sh <<'SH'
#!/bin/sh
printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n%s\n' "$(/tmp/peer.sh)"
SH
cat > /tmp/stream.sh <<'SH'
#!/bin/sh
/tmp/peer.sh; echo
while echo x; do sleep 0.1; done
SH
cat > /tmp/bulk.sh <<'SH'
#!/bin/sh
printf 'HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n'
head -c 262144 /dev/zero
SH
chmod +x /tmp/peer.sh /tmp/echo.sh /tmp/stream.sh /tmp/bulk.sh
socat TCP4-LISTEN:8080,fork,reuseaddr EXEC:/tmp/echo.sh &
socat TCP6-LISTEN:8080,ipv6only=1,fork,reuseaddr EXEC:/tmp/echo.sh &
socat TCP4-LISTEN:8081,fork,reuseaddr EXEC:/tmp/stream.sh &
socat TCP6-LISTEN:8081,ipv6only=1,fork,reuseaddr EXEC:/tmp/stream.sh &
socat TCP4-LISTEN:8082,fork,reuseaddr EXEC:/tmp/bulk.sh &
socat TCP6-LISTEN:8082,ipv6only=1,fork,reuseaddr EXEC:/tmp/bulk.sh &

exec sleep infinity
