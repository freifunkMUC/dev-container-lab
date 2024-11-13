FROM debian:bookworm-slim AS img-convert

ARG DEBIAN_FRONTEND=noninteractive
ARG DISK_SIZE=4G
RUN apt-get update -qy && apt-get install -y qemu-utils

ARG IMAGE
COPY $IMAGE* /

RUN qemu-img convert -O qcow2 /${IMAGE} /gluon.qcow2
RUN qemu-img resize /gluon.qcow2 ${DISK_SIZE}


FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qy \
   && apt-get install -y \
   bridge-utils \
   iproute2 \
   socat \
   qemu-kvm \
   tcpdump \
   ssh \
   inetutils-ping \
   dnsutils \
   iptables \
   nftables \
   telnet \
   cloud-utils \
   sshpass \
   && rm -rf /var/lib/apt/lists/*

COPY --from=img-convert /gluon.qcow2 .
COPY *.py /

EXPOSE 22 5000 10000-10099
HEALTHCHECK CMD ["/healthcheck.py"]
ENTRYPOINT ["/launch.py"]
