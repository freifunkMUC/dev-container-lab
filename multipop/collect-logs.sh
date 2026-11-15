#!/usr/bin/env bash
# Collects the state and logs of the multi-PoP lab into results/logs/.
# shellcheck disable=SC2024  # the logs belong to the user, not to root
set -u
cd "$(dirname "$0")/.." || exit 1
LAB="${LAB:-ffmuc-mp-aa}"
OUT="${RESULTS:-${PWD}/results}/logs"
mkdir -p "${OUT}"
export LAB

for c in $(sudo docker ps -a --format '{{.Names}}' | grep "^clab-${LAB}-"); do
	sudo docker logs "${c}" > "${OUT}/${c#clab-"${LAB}"-}.docker.log" 2>&1
done

for ap in ap-1 ap-2; do
	./node-cmd.sh "${ap}" 'cat /tmp/multipop/status /tmp/multipop/active /tmp/multipop/ra-state /tmp/multipop/dns-servers; ls -l /tmp/multipop; ps w | grep [u]radvd; ip -6 addr; ip -6 rule; ip -6 route show table all; ip -4 route; ip6tables -S; wg show all; cat /tmp/ff-Ohb0ba0u/noderoute.json; logread' 60 \
		> "${OUT}/${ap}.state.log" 2>&1
done

for gw in gateway-gw01 gateway-gw02 gateway-gw03 gateway-gw04; do
	./node-cmd.sh "${gw}" "echo ffmuc | sudo -S sh -c 'ip -br addr; ip -6 route; wg show; vtysh -c \"show bgp summary\"; cat /etc/wgkex-sites.json; journalctl --no-pager -n 300 -u wgkex-broker -u wgkex-worker -u unbound -u jool'" 90 \
		> "${OUT}/${gw}.state.log" 2>&1
done

sudo docker exec "clab-${LAB}-internet" vtysh -c 'show bgp ipv4 unicast' -c 'show bgp ipv6 unicast' \
	> "${OUT}/internet.bgp.log" 2>&1
for c in client-1 client-2 client-3 client-4; do
	sudo docker exec "clab-${LAB}-${c}" sh -c 'ip addr; ip -6 route; ip route' > "${OUT}/${c}.state.log" 2>&1
done
