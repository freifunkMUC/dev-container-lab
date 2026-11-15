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

# The gateway disk (qcow2) is not in the image. containerlab binds it
# read-only to /<name>.qcow2, and qemu writes to an overlay in the container.
# A copy in the image costs about 3 times the disk size during the build.
COPY *.py /

EXPOSE 22 5000 10000-10099
HEALTHCHECK CMD ["/healthcheck.py"]
ENTRYPOINT ["/launch.py"]
