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
	./node-cmd.sh "${gw}" "echo ffmuc | sudo -S sh -c 'ip -br addr; ip -6 route; wg show; vtysh -c \"show bgp summary\"; cat /etc/hosts; ss -tn; journalctl --no-pager -n 300 -u wgkex-worker -u unbound -u jool'" 90 \
		> "${OUT}/${gw}.state.log" 2>&1
done

sudo docker exec "clab-${LAB}-internet" vtysh -c 'show bgp ipv4 unicast' -c 'show bgp ipv6 unicast' \
	> "${OUT}/internet.bgp.log" 2>&1
{
	sudo docker exec "clab-${LAB}-internet" vtysh -c 'show ip bgp 203.0.113.250/32' -c 'show ip route 203.0.113.250'
	sudo docker exec "clab-${LAB}-emqx-a1" runuser -u emqx -- emqx ctl cluster status
	for b in broker-a1 broker-a2 broker-b1 broker-b2; do
		echo "$b: $(sudo docker exec "clab-${LAB}-$b" curl -s -m 2 http://127.0.0.1:5000/api/health)"
	done
} > "${OUT}/control-plane.log" 2>&1
for c in client-1 client-2 client-3 client-4; do
	sudo docker exec "clab-${LAB}-${c}" sh -c 'ip addr; ip -6 route; ip route' > "${OUT}/${c}.state.log" 2>&1
done
