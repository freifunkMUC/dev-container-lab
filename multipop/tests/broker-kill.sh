#!/usr/bin/env bash
# One broker fails (in the site of the haproxy that the home uses). haproxy
# sends the requests to the other brokers.
# Then a pgw of site B fails: the node must report the switch, and the old
# pgw must remove the route of the /63 within 10 s after the report.
TEST="${TEST:-broker-kill}" FAIL=broker exec "$(dirname "$0")/pgw-failure.sh"
