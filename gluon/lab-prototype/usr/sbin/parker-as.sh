#!/bin/sh
# LAB PROTOTYPE: multi-PoP active/standby loop. Not upstream firmware.
# Runs /usr/share/lua/parker-as.lua every 10 s.
while true; do
  lua /usr/share/lua/parker-as.lua || logger -t parker-as "parker-as.lua failed"
  sleep 10
done
