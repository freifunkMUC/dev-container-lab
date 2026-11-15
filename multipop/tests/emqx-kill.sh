#!/usr/bin/env bash
# The EMQX node that the worker of the old pgw uses fails. The worker
# connects to another node of the cluster (mqtt.lab). The broker attached
# to the failed node is unhealthy, so haproxy uses the other brokers.
# Then a pgw of site B fails: the node must report the switch, and the old
# pgw must remove the route of the /63 within 10 s after the report.
TEST="${TEST:-emqx-kill}" FAIL=emqx exec "$(dirname "$0")/pgw-failure.sh"
