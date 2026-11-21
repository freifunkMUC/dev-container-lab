# Runs as root in the Android guest, API 30 and earlier (-net-socket): the
# lab link is eth0 in the "router" namespace of the emulator. Replace its NAT
# and proxies with a bridge from eth0 to wlan1, so that Wi-Fi (wlan0) is on
# the lab LAN. Mobile data off.
R="execns router /system/bin/ip"
for p in dhcpclient dhcpserver ipv6proxy; do pkill -f /vendor/bin/$p; done
sleep 1
execns router /system/bin/iptables -t nat -F POSTROUTING
$R link show br0 >/dev/null 2>&1 || $R link add br0 type bridge
$R addr flush dev eth0
$R addr flush dev wlan1
$R link set eth0 mtu 1500
$R link set wlan1 mtu 1500 || true
$R link set eth0 master br0
$R link set wlan1 master br0
$R link set br0 up
svc data disable
svc wifi disable
sleep 3
svc wifi enable
