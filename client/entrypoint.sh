#!/bin/bash

until [ -e /sys/class/net/lan ]; do sleep 1; done

echo LAN online

dhcpcd -t 0 -w lan

exec sleep infinity
