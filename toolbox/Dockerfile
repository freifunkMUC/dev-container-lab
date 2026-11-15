FROM wbitt/network-multitool:extra
# iproute2, bind-tools, tcpdump and socat: the multi-PoP tests rely on their
# exact output and options.
RUN apk add dnsmasq dhcpcd nftables iproute2 bind-tools tcpdump socat ndisc6
