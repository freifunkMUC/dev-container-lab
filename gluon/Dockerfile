FROM debian:bookworm-slim AS img-convert

ARG DEBIAN_FRONTEND=noninteractive
ARG DISK_SIZE=4G
RUN apt-get update -qy && apt-get install -y qemu-utils

ARG IMAGE
COPY $IMAGE* /

RUN qemu-img convert -O qcow2 /${IMAGE} /gluon.qcow2
RUN qemu-img resize /gluon.qcow2 ${DISK_SIZE}


# LAB PROTOTYPE: uradvd with one RA for all prefixes (multipop/patches).
# launch.py copies it onto the node. build.sh copies the patch here.
FROM alpine:3.20 AS uradvd
ARG URADVD_COMMIT=9c44a2cae9e3573047f152c716950807767a8da3
RUN apk add --no-cache build-base linux-headers curl patch
COPY uradvd.patch /
RUN mkdir /src && cd /src \
   && curl -sfL https://codeload.github.com/freifunkMUC/uradvd/tar.gz/${URADVD_COMMIT} | tar xz --strip-components 1 \
   && patch -p1 < /uradvd.patch \
   && gcc -Wall -Wextra -Werror -Os -static -DVERSION='"multipop"' -o /uradvd uradvd.c \
   && strip /uradvd && gzip -9 /uradvd


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
# LAB PROTOTYPE files for the multi-PoP active/standby lab, see launch.py.
COPY lab-prototype /lab-prototype
COPY --from=uradvd /uradvd.gz /uradvd.gz

EXPOSE 22 5000 10000-10099
HEALTHCHECK CMD ["/healthcheck.py"]
ENTRYPOINT ["/launch.py"]
