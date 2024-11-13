#!/usr/bin/env python3

import datetime
import logging
import os
import re
import signal
import subprocess
import sys

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


class Gateway_vm(vrnetlab.VM):
    def __init__(self):
        for e in os.listdir("/"):
            if re.search(".qcow2$", e):
                disk_image = "/" + e

        super().__init__('', '', disk_image=disk_image, ram=1024)

        self.num_nics = 2
        self.conn_mode = "tc"
        self.nic_type = "virtio-net-pci"

    def bootstrap_spin(self):
        # No fancy serial console parsing for now
        self.running = True
        self.tn.close()

    def gen_mgmt(self):
        """
        Augment the parent class function to change the PCI bus
        """
        # call parent function to generate the mgmt interface
        res = super().gen_mgmt()

        # we need to place mgmt interface on the same bus with other interfaces in Ubuntu,
        # to get nice (predictable) interface names
        if "bus=pci.1" not in res[-3]:
            res[-3] = res[-3] + ",bus=pci.1"
        return res


class Gateway(vrnetlab.VR):
    def __init__(self):
        super().__init__('', '')
        self.vms = [Gateway_vm()]


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="")
    parser.add_argument(
        "--trace", action="store_true", help="enable trace level logging"
    )
    args, _ = parser.parse_known_args()

    LOG_FORMAT = "%(asctime)s: %(module)-10s %(levelname)-8s %(message)s"
    logging.basicConfig(format=LOG_FORMAT)
    logger = logging.getLogger()

    logger.setLevel(logging.DEBUG)
    if args.trace:
        logger.setLevel(1)

    vr = Gateway()
    vr.start()
