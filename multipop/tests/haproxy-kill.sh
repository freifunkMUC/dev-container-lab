#!/usr/bin/env bash
# The haproxy that the home uses fails. Its watchdog withdraws the anycast
# address of broker.lab, so the internet router uses the other haproxy.
# Then a pgw of site B fails: the node must report the switch, and the old
# pgw must remove the route of the /63 within 10 s after the report.
TEST="${TEST:-haproxy-kill}" FAIL=haproxy exec "$(dirname "$0")/pgw-failure.sh"
