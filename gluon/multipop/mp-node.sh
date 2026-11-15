#!/bin/sh
# LAB PROTOTYPE - not production code.
#
# The node side of the Parker multi-PoP design (active/active), built only
# from tools the current firmware has. Each tunnel wg_c<id> goes to one site.
# The broker gives each concentrator the prefixes of its site (site, range6,
# xlat_range6, node_address6, dns64), a list of all pgws of the site, and
# primary_site. Every MP_INTERVAL seconds this script:
#
# - probes all tunnels at the same time (one ICMPv6 echo to the pgw, bound
#   to wg_c<id>, 1 s timeout) and keeps a damped state: down at once when
#   all pgws of the site failed; up after 3 hits, a handshake newer than the
#   down event and MP_DWELL s down. More than MP_MAX_CHANGES changes in
#   MP_CHANGE_WINDOW s give a penalty that doubles each time,
# - selects the next pgw of the same site after 3 misses. This does not
#   change the site state: the prefix stays preferred. The site is down only
#   when all pgws of the site failed (3 misses each, in turn). After the
#   first handshake with the new pgw, it tells the broker (POST
#   /api/v3/switch). The broker tells the old pgw to drop the node /63 route,
# - routes each client prefix only through the tunnel of its site
#   (ip rules 1000, 1050+, 1100+, one table per site),
# - rejects packets to the tunnels with a source of a dead site or a foreign
#   source with ICMPv6 type 1 code 5 (ip6tables chain parker_src),
# - writes the prefixes for the router advertisement to $ST/ra-state for
#   the patched uradvd (multipop/patches/uradvd.patch): preferred while the
#   tunnel is up, preferred lifetime 0 while it is down, not at all when it
#   is down for longer than MP_WITHDRAW_AFTER s. RDNSS: the node addresses.
#   On a change it sends SIGHUP 3 times, 3 s apart,
# - keeps the IPv4 default (with it the CLAT of that tunnel) and the main
#   IPv6 default on the active tunnel. The active tunnel is the primary site
#   while it is up (the damping above delays the switch-back),
# - writes the dnsmasq server list: the DNS64 of the live sites, the active
#   site first.
#
# Status for the lab tests: /tmp/multipop/status, /tmp/multipop/active,
# /tmp/multipop/events ("<epoch> <tunnel> <event> <detail>").

CONF=/tmp/ff-Ohb0ba0u/noderoute.json
ROUTE4_FILE=/tmp/ff-Ohb0ba0u/noderoute-route4
ST=/tmp/multipop
INTERVAL=${MP_INTERVAL:-1}
DOWN_AFTER=${MP_DOWN_AFTER:-3}
UP_AFTER=${MP_UP_AFTER:-3}
HS_MAX=${MP_HS_MAX:-180}
DWELL=${MP_DWELL:-10}
MAX_CHANGES=${MP_MAX_CHANGES:-3}
CHANGE_WINDOW=${MP_CHANGE_WINDOW:-600}
# The first penalty is MP_PENALTY s. Each further one doubles, up to MP_PENALTY_MAX.
PENALTY=${MP_PENALTY:-30}
PENALTY_MAX=${MP_PENALTY_MAX:-600}
# The design example is 10 minutes. The lab uses less to keep the tests short.
WITHDRAW_AFTER=${MP_WITHDRAW_AFTER:-120}
# The names that the node resolves through the WAN (gluon-wan-dnsmasq on
# port 54), not through the DNS64 of a site: the pgw endpoints and the
# broker. The lab DNS64 does not know them, and the node must resolve them
# also when no tunnel is up.
WAN_DOMAINS=${MP_WAN_DOMAINS:-lab}
PREFERRED=${MP_PREFERRED:-300}
VALID=${MP_VALID:-600}
# shellcheck disable=SC1091
[ -r /etc/multipop.conf ] && . /etc/multipop.conf

log() { logger -t mp-node "$*"; }
event() { echo "$(date +%s) $*" >> "$ST/events"; }
conc() { jsonfilter -i "$CONF" -e "@.concentrators[$1].$2" 2>/dev/null; }
pgw() { jsonfilter -i "$CONF" -e "@.concentrators[$1].pgws[$2].$3" 2>/dev/null; }
get() { cat "$ST/$1" 2>/dev/null || echo "${2-0}"; }
put() { echo "$2" > "$ST/$1"; }
wan_dns() { for d in $WAN_DOMAINS; do echo "server=/$d/127.0.0.1#54"; done; }
# resolve_ep <host:port>: prints <address:port>. The pgw switch gives wg an
# address, never a name: if wg cannot resolve a name, it tries again for
# minutes and blocks the loop. The last good answer stays in a cache.
resolve_ep() {
	host=${1%:*} port=${1##*:}
	# An IPv4 or [IPv6] address needs no lookup.
	case "$host" in
	\[*) echo "$1"; return ;;
	*[!0-9.]*) ;;
	*) echo "$1"; return ;;
	esac
	ea=$(nslookup "$host" 127.0.0.1 2>/dev/null |
		awk '/^Name:/ {n = 1} n && /^Address/ {sub(/^Address( [0-9]+)?:[ \t]*/, ""); print; exit}')
	case "$ea" in
	*:*) echo "[$ea]:$port" > "$ST/ep.$host" ;;
	?*) echo "$ea:$port" > "$ST/ep.$host" ;;
	esac
	cat "$ST/ep.$host" 2>/dev/null
}
# One ip rule per pref. busybox prints "<pref>:<TAB>from all ...".
set_rule() {
	pref=$1
	shift
	ip -6 rule show | grep "^$pref:" | grep -qF "$* " && return
	while ip -6 rule del pref "$pref" 2>/dev/null; do :; done
	ip -6 rule add pref "$pref" "$@"
}

mkdir -p "$ST" /var/run

# dnsmasq reads the DNS64 servers from a file that this script writes.
[ -s "$ST/dns-servers" ] || wan_dns > "$ST/dns-servers"
if [ "$(uci -q get dhcp.@dnsmasq[0].serversfile)" != "$ST/dns-servers" ]; then
	uci -q delete dhcp.@dnsmasq[0].server
	uci set dhcp.@dnsmasq[0].serversfile="$ST/dns-servers"
	uci set dhcp.@dnsmasq[0].noresolv=1
	uci commit dhcp
	/etc/init.d/dnsmasq restart
fi

switch_pgw() {
	# Selects the next pgw of the site for tunnel $ifc (index $i). The peer
	# exists on all pgws of the site, so this works without the broker.
	# With one pgw, it adds the same peer again: then WireGuard makes a new
	# handshake when the pgw comes back, and the site can come up at once.
	next=$(((pj + 1) % n))
	key=$(pgw "$i" $next pubkey)
	ka=$(wg show "$ifc" persistent-keepalive | awk '{print $2; exit}')
	ips=$(wg show "$ifc" allowed-ips | awk '{for (i = 2; i <= NF; i++) printf "%s%s", (i > 2 ? "," : ""), $i; exit}')
	[ "$ka" = off ] && ka=0
	[ -n "$key" ] || return
	ep=$(resolve_ep "$(pgw "$i" $next endpoint)")
	[ -n "$ep" ] || { log "$ifc ($site): cannot resolve $(pgw "$i" $next endpoint)"; return; }
	log "$ifc ($site): pgw $(pgw "$i" "$pj" id) does not answer, using pgw $(pgw "$i" $next id)"
	wg set "$ifc" peer "$cur" remove
	wg set "$ifc" peer "$key" endpoint "$ep" \
		persistent-keepalive "${ka:-25}" allowed-ips "${ips:-::/0}"
	echo "$key" > "$ST/pgw.$id"
	put "$ifc.switch_ts" "$now"
	[ "$next" != "$pj" ] || return
	event "$ifc" pgw_switch "$(pgw "$i" "$pj" id) $(pgw "$i" $next id)"
	# Report the switch after the first handshake with the new pgw. With
	# switches in a row, the first old pgw is the one with the route.
	[ -e "$ST/$ifc.report" ] || echo "$(pgw "$i" "$pj" id)" > "$ST/$ifc.report"
	cur=$key
	pj=$next
	gw=$(pgw "$i" $next address6)
}

report_switch() {
	# Tells the broker that $ifc uses pgw $2 now instead of pgw $1. The broker
	# tells the old pgw to drop the node route at once. Without the report,
	# the old pgw drops it when the handshake is older than 180 s.
	[ "$1" != "$2" ] || { rm -f "$ST/$ifc.report"; return; }
	[ -e "$ST/report.lock" ] && return
	server=$(uci -q get parker.nodeconfig.config_server) || return
	key=$(sed 's/+/%2B/g; s#/#%2F#g; s/=/%3D/g' /etc/parker/wg-pubkey)
	touch "$ST/report.lock"
	(
		# libpacketmark: the request goes out over the WAN like nodeconfig.
		if LD_PRELOAD=libpacketmark.so wget -q -T 3 -O /dev/null \
			--post-data "pubkey=$key&old=$1&new=$2" "http://$server/api/v3/switch"; then
			rm -f "$ST/$3.report"
			event "$3" switch_reported "$1 $2"
			log "$3: told the broker that pgw $1 can drop the route"
		fi
		rm -f "$ST/report.lock"
	) </dev/null >/dev/null 2>&1 &
}

change() {
	# Records a state change of $ifc to $1. Returns 1 if the penalty stops it.
	hist=$(awk -v m=$((now - CHANGE_WINDOW)) '$1 > m' "$ST/$ifc.changes" 2>/dev/null)
	# A quiet window resets the penalty.
	[ -n "$hist" ] || put "$ifc.penalties" 0
	if [ "$1" = up ] && [ $(($(echo "$hist" | grep -c .) + 1)) -gt "$MAX_CHANGES" ]; then
		k=$(get "$ifc.penalties")
		p=$PENALTY
		while [ "$k" -gt 0 ] && [ "$p" -lt "$PENALTY_MAX" ]; do p=$((p * 2)); k=$((k - 1)); done
		[ "$p" -le "$PENALTY_MAX" ] || p=$PENALTY_MAX
		put "$ifc.penalties" $(($(get "$ifc.penalties") + 1))
		put "$ifc.penalty" $((now + p))
		# Start a new history, so that the penalty is not set again at its end.
		put "$ifc.changes" "$now"
		event "$ifc" penalty "$p"
		log "$ifc ($site) changed state too often: down for $p s (penalty)"
		return 1
	fi
	printf '%s\n%s\n' "$hist" "$now" | grep . > "$ST/$ifc.changes"
	put "$ifc.state" "$1"
	put "$ifc.since" "$now"
	put "$ifc.${1}_since" "$now"
	event "$ifc" "site_$1" "$site"
}

probe_all() {
	# One echo per tunnel, all at the same time, so a cycle takes about 1 s.
	# Wait only for the pings, not for the RA burst or a switch report.
	pids=""
	for f in "$ST"/wg_c*.gw; do
		[ -e "$f" ] || continue
		t=$(basename "$f" .gw)
		rm -f "$ST/$t.probe"
		(ping -c 1 -W 1 -I "$t" "$(cat "$f")" >/dev/null 2>&1 && touch "$ST/$t.probe") &
		pids="$pids $!"
	done
	# shellcheck disable=SC2086
	[ -z "$pids" ] || wait $pids
}

tunnel() {
	# Brings one tunnel ($1 = index in the concentrator list) in line.
	i=$1
	id=$(conc "$i" id)
	site=$(conc "$i" site)
	ifc=wg_c$id
	range6=$(conc "$i" range6)
	addr=$(conc "$i" node_address6)
	dns=$(conc "$i" dns64)
	table=$((100 + id))
	[ -d "/sys/class/net/$ifc" ] || return

	# The pgw that the tunnel uses now.
	cur=$(wg show "$ifc" peers | head -n 1)
	pj=0
	while key=$(pgw "$i" $pj pubkey) && [ -n "$key" ] && [ "$key" != "$cur" ]; do
		pj=$((pj + 1))
	done
	gw=$(pgw "$i" $pj address6)
	[ -n "$gw" ] || { pj=0; gw=$(conc "$i" address6); }
	n=0
	while [ -n "$(pgw "$i" $n pubkey)" ]; do n=$((n + 1)); done
	[ "$n" -gt 0 ] || n=1

	# Probe and damping. $ifc.tried counts the pgws that failed in turn.
	# probe_all pinged $ST/$ifc.gw. Without it (first cycle), ping here.
	if [ "$(get "$ifc.gw" "")" = "$gw" ]; then
		[ -e "$ST/$ifc.probe" ]
	else
		ping -c 1 -W 1 -I "$ifc" "$gw" >/dev/null 2>&1
	fi
	if [ $? = 0 ]; then
		put "$ifc.hits" $(($(get "$ifc.hits") + 1))
		put "$ifc.misses" 0
		put "$ifc.tried" 0
	else
		put "$ifc.misses" $(($(get "$ifc.misses") + 1))
		put "$ifc.hits" 0
	fi
	hs=$(wg show "$ifc" latest-handshakes | awk '{print $2; exit}')
	age=$((now - ${hs:-0}))
	state=$(get "$ifc.state" down)
	misses=$(get "$ifc.misses")
	tried=$(get "$ifc.tried")
	# All pgws of the site failed: the current one and the n - 1 before it.
	all_failed=0
	[ "$misses" -ge "$DOWN_AFTER" ] && [ $((tried + 1)) -ge "$n" ] && all_failed=1
	in_state=$((now - $(get "$ifc.since")))
	penalty=$(($(get "$ifc.penalty") - now))
	# Fresh: a handshake after the site went down (WireGuard renews it when
	# the pgw comes back, because switch_pgw adds the peer again).
	if [ "$state" = up ] && [ "$all_failed" = 1 ]; then
		change down && state=down
		log "$ifc ($site) is down (all $n pgws failed): deprecating $range6"
	elif [ "$state" = down ] && [ "$in_state" -ge "$DWELL" ] && [ "$penalty" -le 0 ] &&
		[ "$(get "$ifc.hits")" -ge "$UP_AFTER" ] && [ "$age" -le "$HS_MAX" ] &&
		[ "${hs:-0}" -ge "$(get "$ifc.down_since")" ]; then
		change up && state=up && log "$ifc ($site) is up: announcing $range6"
	fi
	# Another pgw of the same site after DOWN_AFTER misses. The site stays
	# up. The new pgw routes the node /63 only after a fresh handshake, and
	# the site comes up again only with a fresh handshake.
	if [ "$misses" -ge "$DOWN_AFTER" ]; then
		switch_pgw
		put "$ifc.misses" 0
		put "$ifc.tried" $((tried + 1))
	fi
	put "$ifc.gw" "$gw"
	# A pending switch report goes out after the first handshake with the new pgw.
	if [ -e "$ST/$ifc.report" ] && [ "${hs:-0}" -ge "$(get "$ifc.switch_ts")" ]; then
		report_switch "$(cat "$ST/$ifc.report")" "$(pgw "$i" "$pj" id)" "$ifc"
	fi

	# The node address on the tunnel, with the pgw as peer.
	if [ "$(get "$ifc.addr" "")" != "$addr $gw" ]; then
		ip -6 addr flush dev "$ifc" scope global
		ip -6 addr add "$addr/128" peer "$gw" dev "$ifc" && put "$ifc.addr" "$addr $gw"
	fi
	ip -6 addr show dev br-client | grep -q "inet6 $addr/64" ||
		ip -6 addr add "$addr/64" dev br-client

	# Source routing: one table per site with a default route without a
	# next hop. Rule 1000 keeps all other routes (the client LAN) in main.
	ip -6 route replace default dev "$ifc" table "$table"
	set_rule $((1049 + id)) to "$dns" iif lo lookup "$table"
	set_rule $((1099 + id)) from "$range6" lookup "$table"

	echo "-s $range6 -j RETURN" >> "$ST/chain.ok"
	echo "-d $gw/128 -p ipv6-icmp --icmpv6-type echo-request -j RETURN" >> "$ST/chain.probe"
	down_since=$(get "$ifc.down_since")
	announced=withdrawn
	if [ "$state" = up ]; then
		live="$live $ifc"
		[ "$site" = "$primary" ] && primary_ifc=$ifc
		echo "$range6,$PREFERRED,$VALID" >> "$ST/ra-state.next"
		announced=$PREFERRED
	else
		echo "-s $range6 -j REJECT --reject-with icmp6-policy-fail" >> "$ST/chain.dead"
		if [ $((now - down_since)) -lt "$WITHDRAW_AFTER" ]; then
			echo "$range6,0,$VALID" >> "$ST/ra-state.next"
			announced=0
		fi
	fi
	echo "rdnss $addr" >> "$ST/rdnss.$([ "$site" = "$primary" ] && echo 1 || echo 2)"
	echo "$ifc $dns" >> "$ST/dns.all"

	put "xlat.$ifc.next" "$(conc "$i" xlat_range6)"
	cmp -s "$ST/xlat.$ifc.next" "$ST/xlat.$ifc" || {
		mv "$ST/xlat.$ifc.next" "$ST/xlat.$ifc"
		clat_changed=1
	}
	[ "$penalty" -gt 0 ] || penalty=0
	[ "${hs:-0}" -gt 0 ] || age=none
	echo "$ifc $site $state $range6 preferred=$announced pgw=$(pgw "$i" $pj id) handshake=${age} changes=$(grep -c . "$ST/$ifc.changes" 2>/dev/null) penalty=$penalty" >> "$ST/status.next"
}

select_active() {
	# The active tunnel: the primary site while it is up, else the current
	# one while it is up, else the first live tunnel.
	old=$(get active "")
	new=$primary_ifc
	[ -z "$new" ] && in_live "$old" && new=$old
	[ -z "$new" ] && new=$(echo "$live" | awk '{print $1}')
	if [ "$new" != "$old" ]; then
		log "active tunnel: ${old:-none} -> ${new:-none}"
		event "${new:-none}" active "${old:-none}"
	fi
	put active "$new"
}

in_live() { case " $live " in *" $1 "*) return 0 ;; esac; return 1; }

move_defaults() {
	# The IPv4 default (with it the CLAT of that tunnel) and the main IPv6
	# default go to the active tunnel. noderoute keeps a route that is on a
	# tunnel with a fresh handshake, so it does not move it back.
	new=$(get active "")
	[ -n "$new" ] || return
	# noderoute can set its own main default, so replace it each cycle.
	ip -6 route replace default dev "$new" proto 23
	cur=$(ip -4 route show default | sed -n 's/.* dev \(wg_c[0-9]*\).*/\1/p' | head -n 1)
	[ -n "$cur" ] && [ "$cur" != "$new" ] || return
	route4=$(cat "$ROUTE4_FILE" 2>/dev/null)
	case "$route4" in
	*"dev $cur "*) route4=$(echo "$route4" | sed "s/dev $cur /dev $new /") ;;
	*) route4=$(ip -4 route show default | head -n 1 | sed "s/dev $cur /dev $new /") ;;
	esac
	log "moving IPv4 from $cur to $new"
	# shellcheck disable=SC2086
	ip -4 route replace $route4 && echo "$route4" > "$ROUTE4_FILE"
}

write_chain() {
	# parker_src: the probes, packet too big, the live prefixes and
	# link-local pass. A dead site and every other source get code 5.
	{
		cat "$ST/chain.probe"
		echo "-p ipv6-icmp --icmpv6-type packet-too-big -j RETURN"
		cat "$ST/chain.dead" 2>/dev/null
		cat "$ST/chain.ok"
		echo "-s fe80::/10 -j RETURN"
		echo "-j REJECT --reject-with icmp6-policy-fail"
	} > "$ST/chain.next"
	cmp -s "$ST/chain.next" "$ST/chain" && return
	ip6tables -w -F parker_src
	while read -r rule; do
		# shellcheck disable=SC2086
		ip6tables -w -A parker_src $rule
	done < "$ST/chain.next"
	mv "$ST/chain.next" "$ST/chain"
	log "reject chain: $(grep -c REJECT "$ST/chain") reject rules"
}

write_dns() {
	act=$(get active "")
	{
		awk -v a="$act" '$1 == a {print "server=" $2}' "$ST/dns.all"
		for t in $live; do
			[ "$t" = "$act" ] || awk -v a="$t" '$1 == a {print "server=" $2}' "$ST/dns.all"
		done
	} > "$ST/dns-servers.next"
	# No live site: try all resolvers.
	[ -s "$ST/dns-servers.next" ] || awk '{print "server=" $2}' "$ST/dns.all" > "$ST/dns-servers.next"
	wan_dns >> "$ST/dns-servers.next"
	cmp -s "$ST/dns-servers.next" "$ST/dns-servers" && return
	mv "$ST/dns-servers.next" "$ST/dns-servers"
	log "dnsmasq servers: $(tr '\n' ' ' < "$ST/dns-servers")"
	for pid in $(pidof dnsmasq); do kill -HUP "$pid"; done
}

radvd_reload() {
	# The uradvd that reads the state file only needs a SIGHUP. It sends an
	# RA at once on each SIGHUP: 3 RAs, 3 s apart. Any other uradvd (the
	# Gluon one from before the first state) needs a restart.
	for pid in $(pidof uradvd); do
		if grep -q state-file "/proc/$pid/cmdline"; then
			(kill -HUP "$pid"; sleep 3; kill -HUP "$pid"; sleep 3; kill -HUP "$pid") 2>/dev/null &
			return
		fi
	done
	/etc/init.d/gluon-radvd restart
}

cycle() {
	[ -r "$CONF" ] || return
	# Not a multi-site answer: leave everything to the firmware.
	[ -n "$(conc 0 site)" ] || return
	now=$(date +%s)
	primary=$(jsonfilter -i "$CONF" -e '@.primary_site' 2>/dev/null)
	cd "$ST" && rm -f ra-state.next rdnss.1 rdnss.2 status.next chain.ok chain.dead chain.probe dns.all
	touch ra-state.next chain.ok chain.probe dns.all
	live=""
	primary_ifc=""
	clat_changed=0

	sh /usr/sbin/mp-fw.sh
	set_rule 1000 lookup main suppress_prefixlength 0
	probe_all

	j=0
	while [ -n "$(conc $j id)" ]; do
		tunnel $j
		j=$((j + 1))
	done
	mv "$ST/status.next" "$ST/status" 2>/dev/null

	select_active
	write_chain
	write_dns
	move_defaults

	# PREF64 only while at least one tunnel is up. uradvd reads it at start.
	if [ -n "$live" ] && [ ! -e "$ST/pref64" ]; then
		echo 64:ff9b::/96 > "$ST/pref64"
		pref64_changed=1
	elif [ -z "$live" ] && [ -e "$ST/pref64" ]; then
		rm -f "$ST/pref64"
		pref64_changed=1
	fi

	cat "$ST/rdnss.1" "$ST/rdnss.2" >> "$ST/ra-state.next" 2>/dev/null
	if ! cmp -s "$ST/ra-state.next" "$ST/ra-state"; then
		mv "$ST/ra-state.next" "$ST/ra-state"
		log "router advertisement: $(tr '\n' ';' < "$ST/ra-state")"
		[ "$pref64_changed" = 1 ] || radvd_reload
	fi
	if [ "$pref64_changed" = 1 ]; then
		log "PREF64: $(cat "$ST/pref64" 2>/dev/null || echo off)"
		/etc/init.d/gluon-radvd restart
		pref64_changed=0
	fi
	[ "$clat_changed" = 1 ] && /etc/init.d/ebpf-clat restart
}

log "starting (lab prototype)"
while true; do
	# A cycle starts every INTERVAL s, or when the previous one ends.
	sleep "$INTERVAL" &
	tick=$!
	cycle
	wait $tick
done
