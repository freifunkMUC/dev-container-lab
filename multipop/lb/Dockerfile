# LAB: the front end of the broker in one site. haproxy sends the node
# requests to the brokers, and FRR announces the anycast address of
# broker.lab while haproxy runs.
FROM quay.io/frrouting/frr:10.1.1
RUN apk add --no-cache haproxy curl
COPY entrypoint.sh /usr/local/bin/lab-lb.sh
ENTRYPOINT ["/usr/local/bin/lab-lb.sh"]
