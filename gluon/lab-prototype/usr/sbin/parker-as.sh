#!/bin/sh
# LAB PROTOTYPE: multi-PoP active/standby daemon. Not upstream firmware.
# parker-as.lua runs a 1 s loop. Restart it when it stops.
while true; do
  lua /usr/share/lua/parker-as.lua loop || logger -t parker-as "parker-as.lua stopped"
  sleep 1
done
