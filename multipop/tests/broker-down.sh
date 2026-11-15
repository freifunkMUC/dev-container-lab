#!/usr/bin/env bash
# All brokers are down, and then a pgw of site B fails. The nodes have the
# pgw list from their last broker answer, so they must change to the other
# pgw of site B without the broker. The worker on that pgw has the peer (the
# broker added it to all pgws of the site) and installs the route of the /63
# when the handshake arrives. The old pgw removes its route after 180 s.
TEST="${TEST:-broker-down}" FAIL=all-brokers exec "$(dirname "$0")/pgw-failure.sh"
