# Runs as root in the Android guest, API 31 and later (-wifi-socket): Wi-Fi
# is the lab link. Stop the DHCP client of the emulator on wlan0: it adds
# IPv4 without a gateway, and then Android stops its CLAT. A real phone has
# only the DHCP client of the platform. Mobile data off.
setprop ctl.stop dhcpclient_wifi
svc data disable
ip -4 addr flush dev wlan0
svc wifi disable
sleep 3
svc wifi enable
