#!/bin/bash

sysctl -w net.ipv6.conf.all.autoconf=0
sysctl -w net.ipv6.conf.all.accept_ra=0

exec /usr/lib/frr/docker-start
