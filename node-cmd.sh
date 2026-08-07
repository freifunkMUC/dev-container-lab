#!/usr/bin/env bash
# Run a shell command on a lab VM via its serial console, non-interactively.
# Usage: ./node-cmd.sh <node> '<command>' [timeout-seconds]
# e.g.:  ./node-cmd.sh ap-1 'wg show all'
#        ./node-cmd.sh gateway-gw01 'ip -br addr'   (logs in as ubuntu/ffmuc)
# Only one serial client can be attached at a time; the vrnetlab launcher
# releases the console once bootstrap is done.
set -eu
node="$1"
cmd="$2"
timeout="${3:-15}"

sudo docker exec -i "clab-ffmuc-${node}" python3 - "$cmd" "$timeout" <<'EOF'
import sys
import telnetlib  # removed in Python 3.13; fine on the lab node images

cmd, timeout = sys.argv[1], int(sys.argv[2])
tn = telnetlib.Telnet("127.0.0.1", 5000, 10)
tn.write(b"\r")
idx, _, res = tn.expect([b"login: ", b"# ", b"\\$ "], 10)
if idx < 0:
    sys.stderr.write("serial console did not answer: %r\n" % res)
    sys.exit(1)
if idx == 0:
    tn.write(b"ubuntu\r")
    tn.expect([b"Password:"], 10)
    tn.write(b"ffmuc\r")
    idx2, _, res = tn.expect([b"\\$ ", b"Login incorrect"], 15)
    if idx2 != 0:
        sys.stderr.write("serial login failed: %r\n" % res)
        sys.exit(1)
# The sentinel is split in the input so only its *output* matches.
tn.write(cmd.encode() + b"; echo @@DO''NE@@\r")
out = tn.read_until(b"@@DONE@@", timeout)
text = out.decode(errors="replace")
# Strip the echoed command line and the sentinel line.
lines = text.splitlines()
if len(lines) < 2:
    sys.stderr.write("command produced no output before the timeout: %r\n" % text)
    sys.exit(1)
sys.stdout.write("\n".join(lines[1:-1]) + "\n")
EOF
