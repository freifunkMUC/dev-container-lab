#!/bin/sh
# LAB PROTOTYPE - not production code.
#
# The node side of the Parker multi-PoP design (active/active), built only
# from tools the current firmware has. Each tunnel goes to one site, and the
# broker gives each concentrator the prefixes of its site (site, range6,
# xlat_range6, node_address6, dns64). Every MP_INTERVAL seconds this script:
#
# - puts the /64 of each site on br-client and the site address on its tunnel,
# - routes each client prefix only through the tunnel of its site,
# - pings the gateway through each tunnel,
# - lets one uradvd instance per site announce its prefix: preferred while
#   the tunnel is up, preferred lifetime 0 while it is down, and not at all
#   when it is down for longer than MP_WITHDRAW_AFTER seconds,
# - rejects client packets from a prefix whose tunnel is down with ICMPv6
#   type 1 code 5 (source address failed ingress/egress policy),
# - moves the IPv4 default route (the CLAT) off a dead tunnel,
# - gives each tunnel's CLAT the xlat /64 of its site.
#
# Status for the lab tests: /tmp/multipop/status.

CONF=/tmp/ff-Ohb0ba0u/noderoute.json
ROUTE4_FILE=/tmp/ff-Ohb0ba0u/noderoute-route4
ST=/tmp/multipop
INTERVAL=${MP_INTERVAL:-5}
DOWN_AFTER=${MP_DOWN_AFTER:-3}
UP_AFTER=${MP_UP_AFTER:-2}
WITHDRAW_AFTER=${MP_WITHDRAW_AFTER:-120}
PREFERRED=120
VALID=180

log() { logger -t mp-node "$*"; }
conc() { jsonfilter -i "$CONF" -e "@.concentrators[$1].$2" 2>/dev/null; }
count() { echo $(($(cat "$ST/$1" 2>/dev/null || echo 0) + 1)) > "$ST/$1"; }

mkdir -p "$ST/radvd"
ip6tables -N mp_reject 2>/dev/null

tunnel() {
	# Brings one tunnel ($1 = index in the concentrator list) in line.
	id=$(conc "$1" id)
	site=$(conc "$1" site)
	ifc=wg_c$id
	range6=$(conc "$1" range6)
	xlat=$(conc "$1" xlat_range6)
	addr=$(conc "$1" node_address6)
	gw=$(conc "$1" address6)
	dns=$(conc "$1" dns64)
	table=$((100 + id))
	[ -d "/sys/class/net/$ifc" ] || return

	# busybox ip does not show the peer, so look only at the address.
	ip -6 addr show dev "$ifc" | grep -q "inet6 $addr/" || {
		ip -6 addr flush dev "$ifc" scope global
		ip -6 addr add "$addr/128" peer "$gw" dev "$ifc"
	}
	ip -6 addr show dev br-client | grep -q "inet6 $addr/64" ||
		ip -6 addr add "$addr/64" dev br-client

	# Source routing. Packets between the client prefixes stay on the LAN.
	ip -6 route replace default dev "$ifc" table "$table"
	ip -6 rule show | grep -q "to $range6 lookup main" ||
		ip -6 rule add to "$range6" lookup main pref 90
	ip -6 rule show | grep -q "from $range6 lookup $table" ||
		ip -6 rule add from "$range6" lookup "$table" pref "$table"

	if ping -c 1 -W 2 -I "$ifc" "$gw" >/dev/null 2>&1; then
		count "$ifc.ok"
		echo 0 > "$ST/$ifc.fail"
	else
		count "$ifc.fail"
		echo 0 > "$ST/$ifc.ok"
	fi
	state=$(cat "$ST/$ifc.state" 2>/dev/null || echo down)
	if [ "$state" = up ] && [ "$(cat "$ST/$ifc.fail")" -ge "$DOWN_AFTER" ]; then
		state=down
		echo "$now" > "$ST/$ifc.down_since"
		log "$ifc ($site) is down: deprecating $range6"
	elif [ "$state" = down ] && [ "$(cat "$ST/$ifc.ok")" -ge "$UP_AFTER" ]; then
		state=up
		log "$ifc ($site) is up: announcing $range6"
	fi
	echo "$state" > "$ST/$ifc.state"

	reject="-s $range6 -j REJECT --reject-with icmp6-policy-fail"
	if [ "$state" = up ]; then
		live="$live $ifc"
		# shellcheck disable=SC2086
		ip6tables -D mp_reject $reject 2>/dev/null
		preferred=$PREFERRED
	else
		# shellcheck disable=SC2086
		ip6tables -C mp_reject $reject 2>/dev/null || ip6tables -A mp_reject $reject
		preferred=0
	fi
	down_for=$((now - $(cat "$ST/$ifc.down_since" 2>/dev/null || echo 0)))
	announced=withdrawn
	if [ "$state" = up ] || [ "$down_for" -lt "$WITHDRAW_AFTER" ]; then
		echo "-i br-client -p $range6 ${dns:+--rdnss $dns} --pref64 64:ff9b::/96 $mtu" \
			"--preferred-lifetime $preferred --valid-lifetime $VALID" > "$ST/radvd.next/$site"
		announced=$preferred
	fi

	echo "$xlat" > "$ST/xlat.$ifc.next"
	cmp -s "$ST/xlat.$ifc.next" "$ST/xlat.$ifc" || {
		mv "$ST/xlat.$ifc.next" "$ST/xlat.$ifc"
		clat_changed=1
	}

	echo "$ifc $site $state $range6 preferred=$announced" >> "$ST/status.next"
}

move_ipv4() {
	# The IPv4 default (and with it the CLAT) stays on one live tunnel.
	# noderoute keeps a route that is on a tunnel it sees as active, so it
	# does not move it back.
	cur=$(ip -4 route show default | sed -n 's/.* dev \(wg_c[0-9]*\).*/\1/p' | head -n 1)
	new=${live# }
	new=${new%% *}
	[ -n "$cur" ] && [ -n "$new" ] || return
	[ "$(cat "$ST/$cur.state" 2>/dev/null)" = down ] || return

	j=0
	while cid=$(conc $j id) && [ -n "$cid" ]; do
		[ "wg_c$cid" = "$new" ] && break
		j=$((j + 1))
	done
	route4=$(cat "$ROUTE4_FILE" 2>/dev/null)
	case "$route4" in
	*"dev $cur "*) route4=$(echo "$route4" | sed "s/dev $cur /dev $new /") ;;
	*) route4="default via $(conc $j address4) dev $new proto 23" ;;
	esac
	log "moving IPv4 from $cur to $new"
	# shellcheck disable=SC2086
	ip -4 route replace $route4 && echo "$route4" > "$ROUTE4_FILE"
	ip -6 route replace default via "$(conc $j address6)" dev "$new" proto 23
}

cycle() {
	[ -r "$CONF" ] || return
	# Not a multi-site answer: leave everything to the firmware.
	[ -n "$(conc 0 site)" ] || return
	now=$(date +%s)
	mtu=""
	[ -r /tmp/adv_mtu ] && mtu="--adv-link-mtu $(cat /tmp/adv_mtu)"
	rm -rf "$ST/radvd.next" "$ST/status.next"
	mkdir -p "$ST/radvd.next"
	live=""
	clat_changed=0

	ip6tables -C FORWARD -j mp_reject 2>/dev/null || ip6tables -I FORWARD 1 -j mp_reject

	i=0
	while [ -n "$(conc $i id)" ]; do
		tunnel $i
		i=$((i + 1))
	done
	mv "$ST/status.next" "$ST/status" 2>/dev/null

	if [ "$(cat "$ST"/radvd/* 2>/dev/null)" != "$(cat "$ST"/radvd.next/* 2>/dev/null)" ]; then
		rm -rf "$ST/radvd"
		mv "$ST/radvd.next" "$ST/radvd"
		log "router advertisements: $(cat "$ST"/radvd/* | tr '\n' ';')"
		/etc/init.d/gluon-radvd restart
	fi
	[ "$clat_changed" = 1 ] && /etc/init.d/ebpf-clat restart
	move_ipv4
}

log "starting (lab prototype)"
while true; do
	cycle
	sleep "$INTERVAL"
done
