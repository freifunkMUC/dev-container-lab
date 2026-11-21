# wgkex broker for the lab broker plane. LAB PROTOTYPE.
# Build context: the patched wgkex source (gateway/packer/wgkex-src), see build.sh.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
	&& rm -rf /var/lib/apt/lists/*
COPY . /opt/wgkex/src
WORKDIR /opt/wgkex/src
RUN pip install --no-cache-dir -r requirements.txt
ENV PYTHONUNBUFFERED=1 WGKEX_CONFIG_FILE=/tmp/wgkex.yaml
CMD ["python", "-m", "wgkex.broker.app"]
