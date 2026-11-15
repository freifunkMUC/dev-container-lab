#!/bin/sh
# LAB PROTOTYPE - not production code.
#
# The node side of the Parker multi-PoP design (active/active), built only
# from tools the current firmware has. Each tunnel wg_c<id> goes to one site.
# The broker gives each concentrator the prefixes of its site (site, range6,
# xlat_range6, node_address6, dns64), a list of all pgws of the site, and
# primary_site. Every MP_INTERVAL seconds this script:
#
# - probes each tunnel (one ICMPv6 echo to the pgw, bound to wg_c<id>) and
#   keeps a damped state: down after 3 misses or an old handshake, up after
#   3 hits and a fresh handshake, at least MP_DWELL s in a state, a penalty
#   after too many changes,
# - selects the next pgw of the same site when the probe fails,
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
#   while it is up. After a failover it goes back to the primary site only
#   after the primary site was up for MP_HOLD_DOWN s,
# - writes the dnsmasq server list: the DNS64 of the live sites, the active
#   site first.
#
# Status for the lab tests: /tmp/multipop/status, /tmp/multipop/active.

CONF=/tmp/ff-Ohb0ba0u/noderoute.json
ROUTE4_FILE=/tmp/ff-Ohb0ba0u/noderoute-route4
ST=/tmp/multipop
INTERVAL=${MP_INTERVAL:-10}
DOWN_AFTER=${MP_DOWN_AFTER:-3}
UP_AFTER=${MP_UP_AFTER:-3}
HS_MAX=${MP_HS_MAX:-180}
DWELL=${MP_DWELL:-60}
HOLD_DOWN=${MP_HOLD_DOWN:-120}
MAX_CHANGES=${MP_MAX_CHANGES:-3}
CHANGE_WINDOW=${MP_CHANGE_WINDOW:-600}
PENALTY=${MP_PENALTY:-600}
# The design example is 10 minutes. The lab uses less to keep the tests short.
WITHDRAW_AFTER=${MP_WITHDRAW_AFTER:-120}
PREFERRED=${MP_PREFERRED:-300}
VALID=${MP_VALID:-600}
# shellcheck disable=SC1091
[ -r /etc/multipop.conf ] && . /etc/multipop.conf

log() { logger -t mp-node "$*"; }
conc() { jsonfilter -i "$CONF" -e "@.concentrators[$1].$2" 2>/dev/null; }
pgw() { jsonfilter -i "$CONF" -e "@.concentrators[$1].pgws[$2].$3" 2>/dev/null; }
get() { cat "$ST/$1" 2>/dev/null || echo "${2-0}"; }
put() { echo "$2" > "$ST/$1"; }
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
if [ "$(uci -q get dhcp.@dnsmasq[0].serversfile)" != "$ST/dns-servers" ]; then
	touch "$ST/dns-servers"
	uci -q delete dhcp.@dnsmasq[0].server
	uci set dhcp.@dnsmasq[0].serversfile="$ST/dns-servers"
	uci set dhcp.@dnsmasq[0].noresolv=1
	uci commit dhcp
	/etc/init.d/dnsmasq restart
fi

switch_pgw() {
	# Selects the next pgw of the site for tunnel $ifc (index $i). The peer
	# exists on all pgws of the site, so this works without the broker.
	n=0
	while [ -n "$(pgw "$i" $n pubkey)" ]; do n=$((n + 1)); done
	[ "$n" -gt 1 ] || return
	next=$(((pj + 1) % n))
	key=$(pgw "$i" $next pubkey)
	ka=$(wg show "$ifc" persistent-keepalive | awk '{print $2; exit}')
	ips=$(wg show "$ifc" allowed-ips | awk '{for (i = 2; i <= NF; i++) printf "%s%s", (i > 2 ? "," : ""), $i; exit}')
	[ "$ka" = off ] && ka=0
	log "$ifc ($site): pgw $(pgw "$i" "$pj" id) does not answer, using pgw $(pgw "$i" $next id)"
	wg set "$ifc" peer "$cur" remove
	wg set "$ifc" peer "$key" endpoint "$(pgw "$i" $next endpoint)" \
		persistent-keepalive "${ka:-25}" allowed-ips "${ips:-::/0}"
	echo "$key" > "$ST/pgw.$id"
	cur=$key
	pj=$next
	gw=$(pgw "$i" $next address6)
}

change() {
	# Records a state change of $ifc to $1. Returns 1 if the penalty stops it.
	hist=$(awk -v m=$((now - CHANGE_WINDOW)) '$1 > m' "$ST/$ifc.changes" 2>/dev/null)
	if [ "$1" = up ] && [ $(($(echo "$hist" | grep -c .) + 1)) -gt "$MAX_CHANGES" ]; then
		put "$ifc.penalty" $((now + PENALTY))
		# Start a new history, so that the penalty is not set again at its end.
		put "$ifc.changes" "$now"
		log "$ifc ($site) changed state too often: down for ${PENALTY} s (penalty)"
		return 1
	fi
	printf '%s\n%s\n' "$hist" "$now" | grep . > "$ST/$ifc.changes"
	put "$ifc.state" "$1"
	put "$ifc.since" "$now"
	put "$ifc.${1}_since" "$now"
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

	# Probe and damping.
	if ping -c 1 -W 2 -I "$ifc" "$gw" >/dev/null 2>&1; then
		put "$ifc.hits" $(($(get "$ifc.hits") + 1))
		put "$ifc.misses" 0
	else
		put "$ifc.misses" $(($(get "$ifc.misses") + 1))
		put "$ifc.hits" 0
	fi
	hs=$(wg show "$ifc" latest-handshakes | awk '{print $2; exit}')
	age=$((now - ${hs:-0}))
	state=$(get "$ifc.state" down)
	misses=$(get "$ifc.misses")
	in_state=$((now - $(get "$ifc.since")))
	penalty=$(($(get "$ifc.penalty") - now))
	if [ "$state" = up ] && [ "$in_state" -ge "$DWELL" ] &&
		{ [ "$misses" -ge "$DOWN_AFTER" ] || [ "$age" -gt "$HS_MAX" ]; }; then
		change down && state=down
		log "$ifc ($site) is down (misses $misses, handshake ${age} s): deprecating $range6"
	elif [ "$state" = down ] && [ "$in_state" -ge "$DWELL" ] && [ "$penalty" -le 0 ] &&
		[ "$(get "$ifc.hits")" -ge "$UP_AFTER" ] && [ "$age" -le "$HS_MAX" ]; then
		change up && state=up && log "$ifc ($site) is up: announcing $range6"
	fi
	# Another pgw of the same site after each DOWN_AFTER misses.
	[ "$misses" -gt 0 ] && [ $((misses % DOWN_AFTER)) = 0 ] && switch_pgw

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
	echo "$ifc $site $state $range6 preferred=$announced pgw=$(pgw "$i" $pj id) handshake=${age} changes=$(grep -c . "$ST/$ifc.changes" 2>/dev/null) penalty=$penalty" >> "$ST/status.next"
}

select_active() {
	# The active tunnel: the primary site, else the current one while it is
	# up, else the first live tunnel. Back to the primary site only after it
	# was up for HOLD_DOWN s.
	old=$(get active "")
	new=""
	if [ -n "$primary_ifc" ]; then
		if [ -z "$old" ] || [ "$old" = "$primary_ifc" ] || ! in_live "$old" ||
			[ $((now - $(get "$primary_ifc.up_since"))) -ge "$HOLD_DOWN" ]; then
			new=$primary_ifc
		fi
	fi
	[ -z "$new" ] && in_live "$old" && new=$old
	[ -z "$new" ] && new=$(echo "$live" | awk '{print $1}')
	[ "$new" = "$old" ] || log "active tunnel: ${old:-none} -> ${new:-none}"
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
	cycle
	sleep "$INTERVAL"
done
