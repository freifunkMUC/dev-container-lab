#!/usr/bin/env python3

import datetime
import logging
import os
import re
import signal
import subprocess
import sys
import time

import vrnetlab


def handle_SIGCHLD(signal, frame):
    os.waitpid(-1, os.WNOHANG)


def handle_SIGTERM(signal, frame):
    sys.exit(0)


signal.signal(signal.SIGINT, handle_SIGTERM)
signal.signal(signal.SIGTERM, handle_SIGTERM)
signal.signal(signal.SIGCHLD, handle_SIGCHLD)

TRACE_LEVEL_NUM = 9
logging.addLevelName(TRACE_LEVEL_NUM, "TRACE")


def trace(self, message, *args, **kws):
    # Yes, logger takes its '*args' as 'args'.
    if self.isEnabledFor(TRACE_LEVEL_NUM):
        self._log(TRACE_LEVEL_NUM, message, args, **kws)


logging.Logger.trace = trace


# LAB PROTOTYPE of the multi-PoP node side, see multipop/mp-node.sh. The
# files go onto the node through the serial console.
MULTIPOP_DIR = "/multipop"
MULTIPOP_FILES = {
    "/usr/sbin/mp-node.sh": "mp-node.sh",
    "/etc/init.d/mp-node": "mp-node.init",
    "/etc/init.d/gluon-radvd": "gluon-radvd.init",
    "/etc/init.d/ebpf-clat": "ebpf-clat.init",
}
# nodeconfig puts the address of the first site on every tunnel. With these
# edits each tunnel gets the node address of its own site, if the broker
# sends one.
NODECONFIG_SED = (
    "sed -i"
    " -e 's/\"inet6 \"\\.\\.o\\.address6\\.\\./\"inet6 \"..(a.node_address6 or o.address6)../'"
    " -e 's/\"ip -6 addr replace \"\\.\\.o\\.address6\\.\\./\"ip -6 addr replace \"..(a.node_address6 or o.address6)../'"
    " /usr/share/lua/nodeconfig.lua"
)


def multipop_cmds():
    if not os.path.isdir(MULTIPOP_DIR):
        return []
    cmds = []
    for path, name in MULTIPOP_FILES.items():
        with open(os.path.join(MULTIPOP_DIR, name)) as f:
            # A tab on the serial console would start completion in ash.
            lines = f.read().expandtabs(4).splitlines()
        cmds.append(f": > {path}")
        for line in lines:
            quoted = line.replace("'", "'\\''")
            cmds.append(f"printf '%s\\n' '{quoted}' >> {path}")
        cmds.append(f"chmod 755 {path}")
    cmds += uradvd_cmds()
    cmds += [NODECONFIG_SED, "/etc/init.d/mp-node enable"]
    return cmds


# The node has no base64, so the patched uradvd goes over as hex lines, and
# lua turns them back into bytes.
URADVD_HEX_DECODE = (
    "lua -e 'local d = io.open(\"/tmp/uradvd.hex\"):read(\"*a\"):gsub(\"%s\", \"\")"
    ":gsub(\"%x%x\", function(h) return string.char(tonumber(h, 16)) end)"
    " local f = io.open(\"/tmp/uradvd.gz\", \"wb\") f:write(d) f:close()'"
)


def uradvd_cmds():
    path = os.path.join(MULTIPOP_DIR, "uradvd.gz")
    if not os.path.isfile(path):
        return []
    with open(path, "rb") as f:
        data = f.read().hex()
    cmds = [": > /tmp/uradvd.hex"]
    cmds += [f"echo {data[i:i + 400]} >> /tmp/uradvd.hex" for i in range(0, len(data), 400)]
    cmds += [
        URADVD_HEX_DECODE,
        "gunzip -c /tmp/uradvd.gz > /usr/sbin/uradvd && chmod 755 /usr/sbin/uradvd",
        "rm -f /tmp/uradvd.hex /tmp/uradvd.gz",
    ]
    return cmds


class Gluon_vm(vrnetlab.VM):
    def __init__(self, hostname):
        super().__init__('', '', disk_image='/gluon.qcow2', ram=512)

        self.hostname = hostname

        self.num_nics = 2
        self.conn_mode = "tc"
        self.nic_type = "virtio-net-pci"

        self.wait_pattern = ':/# '  # Shell prompt on serial console, adjusted after wake-up

    def configure(self):
        cmds = [
            "uci set gluon-setup-mode.@setup_mode[0].configured=1",
            f"uci set system.@system[0].hostname={self.hostname}",
        ]

        # SSHKEY may carry several authorized_keys lines; the serial console
        # takes one command per line, so write them one echo at a time.
        for n, key in enumerate(os.environ.get("SSHKEY", "").splitlines()):
            redirect = ">" if n == 0 else ">>"
            cmds.append(f"echo '{key}' {redirect} /etc/dropbear/authorized_keys")

        if os.environ.get("MESHONWAN", "") == "1":
            # Mesh with the other APs on the LAN our WAN port hangs off. The
            # role only turns into a network configuration once the upgrade
            # scripts below have run.
            cmds += [
                "uci -q del_list gluon.iface_wan.role='mesh'",
                "uci add_list gluon.iface_wan.role='mesh'",
            ]

        # 906-parker-nodeconfig copies the config server and the key its
        # answers are verified with out of site.conf and into uci every time
        # the upgrade scripts run, so our overrides have to come after the last
        # run of them. Nothing runs them again on the boots that follow.
        cmds += [
            "uci commit",
            "gluon-reconfigure",
            f"uci set parker.nodeconfig.config_server={os.environ.get('CONFIGSERVER', '')}",
        ]

        config_pubkey = os.environ.get("CONFIGPUBKEY", "")
        if config_pubkey:
            cmds.append(f"uci set parker.nodeconfig.config_pubkey={config_pubkey}")

        cmds += multipop_cmds()
        cmds += [
            "uci commit",
            "sync",
        ]

        for line in cmds:
            self.wait_write(line)
        time.sleep(1)
        self.wait_write("reboot")

    def bootstrap_spin(self):
        """This function should be called periodically to do work."""

        if self.spins > 6000:
            # too many spins with no result ->  give up
            self.logger.debug("Too many spins -> give up")
            self.stop()
            self.start()
            return

        (ridx, match, res) = self.tn.expect([b"br-setup"], 1)
        if match:  # got a match!
            if ridx == 0:  # login
                self.logger.info("setup is online")
                # The console shell only spawns once Enter is pressed, and a
                # single newline sent while getty is still starting up gets
                # swallowed. Poke until the shell actually answers.
                for attempt in range(60):
                    self.tn.write(b"\r")
                    res = self.tn.read_until(b"# ", 5)
                    if b":/# " in res or b":~# " in res:
                        break
                    self.logger.trace(
                        "no prompt yet (attempt %d): %r", attempt + 1, res
                    )
                else:
                    self.logger.error("serial console never presented a prompt")
                    return
                # the shell's cwd (and thus the prompt) differs between
                # images: FFBS prompts ':/# ', FFMUC ':~# ' -- match what
                # this image actually presented
                self.wait_pattern = ':~# ' if b":~# " in res else ':/# '
                # queue a fresh prompt for configure()'s first wait_write
                self.tn.write(b"\r")

                self.configure()

                self.running = True
                # close telnet connection
                self.tn.close()
                # startup time?
                startup_time = datetime.datetime.now() - self.start_time
                self.logger.info("Startup complete in: %s", startup_time)
                return

        # no match, if we saw some output from the router it's probably
        # booting, so let's give it some more time
        if res != b"":
            sys.stdout.buffer.write(res)
            sys.stdout.buffer.flush()
            # reset spins if we saw some output
            self.spins = 0

        self.spins += 1

    def gen_mgmt(self):
        # No mgmt interface for now
        return []


class Gluon(vrnetlab.VR):
    def __init__(self, hostname):
        super().__init__('', '')
        self.vms = [Gluon_vm(hostname)]


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="")
    parser.add_argument(
        "--trace", action="store_true", help="enable trace level logging"
    )
    parser.add_argument("--hostname", default="ubuntu", help="VM Hostname")
    args, _ = parser.parse_known_args()

    LOG_FORMAT = "%(asctime)s: %(module)-10s %(levelname)-8s %(message)s"
    logging.basicConfig(format=LOG_FORMAT)
    logger = logging.getLogger()

    logger.setLevel(logging.DEBUG)
    if args.trace:
        logger.setLevel(1)

    vr = Gluon(args.hostname)
    vr.start()
