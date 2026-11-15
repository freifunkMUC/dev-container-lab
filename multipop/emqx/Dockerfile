# LAB: one node of the MQTT cluster, the same EMQX version as in production
# (Apache-2.0). It runs as root only to set its address; EMQX itself runs as
# the emqx user (see entrypoint.sh).
FROM emqx/emqx:5.8.9
USER root
RUN apt-get update \
	&& apt-get install -y --no-install-recommends iproute2 \
	&& rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/lab-emqx.sh
ENTRYPOINT ["/usr/local/bin/lab-emqx.sh"]
