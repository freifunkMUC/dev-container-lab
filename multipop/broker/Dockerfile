# LAB: the wgkex broker as a separate service, like in production. The source
# is the patched wgkex tree that build.sh copies to gateway/packer/wgkex-src:
#   docker build --build-context wgkex=gateway/packer/wgkex-src multipop/broker
FROM python:3.12-slim
RUN apt-get update \
	&& apt-get install -y --no-install-recommends iproute2 curl \
	&& rm -rf /var/lib/apt/lists/*
COPY --from=wgkex requirements.txt /opt/wgkex/requirements.txt
RUN pip install --no-cache-dir -r /opt/wgkex/requirements.txt
COPY --from=wgkex wgkex /opt/wgkex/wgkex
COPY wgkex.yaml sites.json entrypoint.sh /etc/wgkex/
WORKDIR /opt/wgkex
ENV PYTHONUNBUFFERED=1 WGKEX_CONFIG_FILE=/run/wgkex.yaml \
	WGKEX_SITES_FILE=/etc/wgkex/sites.json
ENTRYPOINT ["/etc/wgkex/entrypoint.sh"]
