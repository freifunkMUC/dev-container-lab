#!/usr/bin/env bash
# The broker is down, and then a pgw of site B fails. The nodes have the
# pgw list from their last broker answer, so they must change to the other
# pgw of site B without the broker. The worker on that pgw has the peer (the
# broker added it to all pgws of the site) and installs the route of the /63
# when the handshake arrives.
TEST="${TEST:-broker-down}" BROKER_DOWN=1 exec "$(dirname "$0")/pgw-failure.sh"
