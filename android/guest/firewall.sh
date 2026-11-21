# Runs as root in the Android guest. Drops new inbound TCP and UDP on the lab
# link (adbd listens on all addresses on API 30 and later). Replies, ICMP,
# DHCP, DHCPv6 and mDNS pass.
for T in iptables ip6tables; do
	$T -N labfw 2>/dev/null
	$T -F labfw
	$T -A labfw -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
	$T -A labfw -p tcp -j DROP
	$T -A labfw -p udp --dport 68 -j RETURN
	$T -A labfw -p udp --dport 546 -j RETURN
	$T -A labfw -p udp --dport 5353 -j RETURN
	$T -A labfw -p udp -m conntrack --ctstate NEW -j DROP
	for i in wlan0 eth0; do
		$T -D INPUT -i $i -j labfw 2>/dev/null
		$T -I INPUT 1 -i $i -j labfw
	done
done
echo "labfw: $(iptables -S labfw | wc -l) IPv4 and $(ip6tables -S labfw | wc -l) IPv6 rules"
