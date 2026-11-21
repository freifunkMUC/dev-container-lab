FROM wbitt/network-multitool:extra
# iproute2, bind-tools, tcpdump and socat: the multi-PoP tests rely on their
# exact output and options. iputils (ping -D), coreutils (date +%N), curl and
# python3: the client traffic monitor (tests/clientmon.sh, tests/monsrv.py).
RUN apk add dnsmasq dhcpcd nftables iproute2 bind-tools tcpdump socat ndisc6 \
	iputils coreutils curl python3
