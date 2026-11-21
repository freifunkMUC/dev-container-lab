# Android emulator as a containerlab node. The image has no Android SDK:
# android/fetch-sdk.sh downloads it, and the topology binds it to /sdk.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	python3 iproute2 procps ca-certificates \
	libpulse0 libgl1 libnss3 libxcomposite1 libxcursor1 libxdamage1 libxi6 libxtst6 \
	libxrandr2 libxkbfile1 libx11-xcb1 libasound2t64 libdbus-1-3 libbsd0 libgbm1 \
	&& rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh relay.py /
COPY guest /guest
ENTRYPOINT ["/entrypoint.sh"]
