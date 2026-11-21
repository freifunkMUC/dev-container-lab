# The internet of the ffbs environment, and the far end of the exit tunnel:
# in production, exit1 sends the client traffic to a VPN provider.
FROM alpine:3.20
RUN apk add --no-cache iproute2 wireguard-tools iputils tcpdump
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
