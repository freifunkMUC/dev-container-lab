#!/usr/bin/env python3

import datetime
import logging
import os
import re
import signal
import subprocess
import sys
import time
import textwrap

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


class Gluon_vm(vrnetlab.VM):
    def __init__(self, hostname):
        super().__init__('', '', disk_image='/gluon.qcow2', ram=512)

        self.hostname = hostname

        self.num_nics = 2
        self.conn_mode = "tc"
        self.nic_type = "virtio-net-pci"

        self.wait_pattern = ':/# '  # Shell prompt on serial console

    def configure(self):
        cmds = f'''\
            uci set gluon-setup-mode.@setup_mode[0].configured=1
            uci set system.@system[0].hostname={self.hostname}
            uci set parker.nodeconfig.config_server={os.environ.get('CONFIGSERVER', '')}
            echo '{os.environ.get('SSHKEY', '')}' > /etc/dropbear/authorized_keys
            uci commit
            sync
        '''
        for line in textwrap.dedent(cmds).splitlines():
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
                self.wait_write("", wait=None)

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
