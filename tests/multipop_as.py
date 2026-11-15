#!/usr/bin/env python3
"""Tests for the multi-PoP active/standby lab (clab name ffmuc-mp-as).

Usage: tests/multipop_as.py [--results DIR] [TEST ...]
Tests, in this order: ready normal source-prefix inbound-standby
failover-vie recovery-vie failover-muc recovery-muc. Without TEST: all.

Each test prints its evidence and writes DIR/test-NN-<test>.json with
{"name", "pass", "evidence": [...]}. Exit 0 only when all selected tests pass.
"""

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import time

LAB = os.environ.get("LAB", "ffmuc-mp-as")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TARGET6 = "2001:db8:cafe::1"
TARGET4 = "203.0.113.42"
TARGET_DNS64 = "64:ff9b::cb00:712a"  # internet.lab A 203.0.113.42 through DNS64

SITES = {
    "muc": {"prefix": ipaddress.ip_network("2001:db8:100::/48"),
            "dns64": "2001:db8:100::53", "gws": ["gw01", "gw02"],
            "pool4": {"198.51.100.11", "198.51.100.12"}},
    "vie": {"prefix": ipaddress.ip_network("2001:db8:200::/48"),
            "dns64": "2001:db8:200::53", "gws": ["gw03", "gw04"],
            "pool4": {"198.51.100.13", "198.51.100.14"}},
}
# Each home: its AP, its clients and the primary site the broker gives it.
HOMES = {
    "home1": {"ap": "ap-1", "clients": ["client-1", "client-2"], "primary": "muc"},
    "home2": {"ap": "ap-2", "clients": ["client-3", "client-4"], "primary": "vie"},
}
OTHER = {"muc": "vie", "vie": "muc"}

# Handshake ageing (180 s) plus RA and polling slack.
FAILOVER_TIMEOUT = int(os.environ.get("FAILOVER_TIMEOUT", "420"))
# DEAD_KEEP (180 s) in parker-as.lua plus slack.
WITHDRAW_TIMEOUT = int(os.environ.get("WITHDRAW_TIMEOUT", "300"))
READY_TIMEOUT = int(os.environ.get("READY_TIMEOUT", "1500"))


class Check:
    def __init__(self, name):
        self.name = name
        self.ok = True
        self.evidence = []

    def log(self, msg):
        print(f"[{self.name}] {msg}", flush=True)
        self.evidence.append(msg)

    def expect(self, cond, msg):
        self.log(("PASS " if cond else "FAIL ") + msg)
        if not cond:
            self.ok = False
        return cond


def run(argv, timeout=60):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout or b""
        if isinstance(out, bytes):
            out = out.decode(errors="replace")
        return 124, out


def last(out):
    lines = out.strip().splitlines()
    return lines[-1] if lines else ""


def dx(node, cmd, timeout=60):
    """Run a shell command in a container node."""
    return run(["sudo", "docker", "exec", f"clab-{LAB}-{node}", "sh", "-c", cmd], timeout)


def inet_argv(cmd):
    """A command in the netns of the internet node, with the toolbox tools."""
    return ["sudo", "docker", "run", "--rm", "--net", f"container:clab-{LAB}-internet",
            "ffmuc-lab:toolbox", "sh", "-c", cmd]


def vm(node, cmd, timeout=20):
    """Run a command on a VM node (AP or gateway) over its serial console."""
    return run([os.path.join(ROOT, "node-cmd.sh"), node, cmd, str(timeout)], timeout + 30)


def wait_for(fn, timeout, step=10):
    end = time.time() + timeout
    while True:
        result = fn()
        if result or time.time() > end:
            return result
        time.sleep(step)


def site_of(addr):
    try:
        a = ipaddress.ip_address(addr)
    except ValueError:
        return None
    for name, site in SITES.items():
        if a.version == 6 and a in site["prefix"]:
            return name
    return None


def pool4_site(addr):
    for name, site in SITES.items():
        if addr in site["pool4"]:
            return name
    return None


def ap_status(ap):
    """parker-as status of an AP as a dict."""
    _, out = vm(ap, "cat /tmp/parker-as/status")
    st = {"raw": " | ".join(out.strip().splitlines()), "sites": {}}
    for line in out.splitlines():
        line = line.strip()
        m = re.match(r"(primary_site|effective)=(\S+)", line)
        if m:
            st[m.group(1)] = m.group(2)
        m = re.match(r"site (\S+) (live|dead) iface=(\S+) range6=(\S+) ra=(on|off)", line)
        if m:
            st["sites"][m.group(1)] = {"state": m.group(2), "iface": m.group(3),
                                       "range6": m.group(4), "ra": m.group(5)}
    return st


def wait_status(ap, pred, timeout):
    def poll():
        st = ap_status(ap)
        return st if pred(st) else None
    return wait_for(poll, timeout)


def client_addrs(client):
    """Global IPv6 addresses of a client: {site: (addr, deprecated)}."""
    _, out = dx(client, "ip -6 -o addr show dev lan scope global")
    result = {}
    for line in out.splitlines():
        m = re.search(r"inet6 ([0-9a-f:]+)/64", line)
        if m and site_of(m.group(1)):
            result[site_of(m.group(1))] = (m.group(1), "deprecated" in line)
    return result


def preferred(addrs, site):
    return site in addrs and not addrs[site][1]


def deprecated_or_gone(addrs, site):
    return site not in addrs or addrs[site][1]


def route_src(client, dst=TARGET6):
    _, out = dx(client, f"ip -6 route get {dst}")
    m = re.search(r"src ([0-9a-f:]+)", out)
    return m.group(1) if m else None


def ping(node, dst, extra="", count=3):
    six = "-6 " if ":" in dst else ""
    rc, out = dx(node, f"ping {six}{extra} -c {count} -W 2 {dst}", timeout=30)
    return rc == 0, out


def seen_source(client, dst):
    """Ping dst from the client. Return the source address the internet node
    sees on the echo requests, and the tcpdump line."""
    if ":" in dst:
        filt = f"icmp6 and ip6[40] == 128 and dst host {dst}"
    else:
        filt = f"icmp and icmp[icmptype] == 8 and dst host {dst}"
    p = subprocess.Popen(inet_argv(f"timeout 20 tcpdump -lnni any -c 1 '{filt}' 2>/dev/null"),
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    time.sleep(5)
    ping(client, dst, count=4)
    try:
        out, _ = p.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        p.kill()
        out = ""
    m = re.search(r"IP6? ([0-9a-f.:]+) > ", out)
    return (m.group(1) if m else None), out.strip()


def route4_dev(ap):
    # busybox ip ignores "proto" in show, so pick the default via a tunnel.
    _, out = vm(ap, "ip -4 route show | grep '^default via'")
    m = re.search(r"dev (\S+)", out)
    return m.group(1) if m else None


def set_site_links(site, state):
    for gw in SITES[site]["gws"]:
        dx("internet", f"ip link set {gw} {state}")


def home_with_primary(site):
    return next(h for h in HOMES.values() if h["primary"] == site)


# ---------------------------------------------------------------- tests

def t_ready(c):
    """The lab is up: each AP has two live sites and the right primary, and
    each client has an address from both sites."""
    def ready():
        for home in HOMES.values():
            st = ap_status(home["ap"])
            if st.get("effective") != home["primary"] or len(st["sites"]) != 2 or \
                    any(s["state"] != "live" for s in st["sites"].values()):
                return False
            for cl in home["clients"]:
                if set(client_addrs(cl)) != {"muc", "vie"}:
                    return False
        return True

    t0 = time.time()
    c.expect(wait_for(ready, READY_TIMEOUT, step=20), f"lab ready after {int(time.time() - t0)} s")
    for home in HOMES.values():
        st = ap_status(home["ap"])
        c.log(f"{home['ap']} status: {st['raw']}")
        c.expect(st.get("primary_site") == home["primary"],
                 f"{home['ap']} primary_site from broker = {st.get('primary_site')} (want {home['primary']})")
        for cl in home["clients"]:
            c.log(f"{cl} addresses: {client_addrs(cl)}")


def t_normal(c):
    """IPv6, IPv4 through the CLAT, and DNS64 work for every client."""
    for home in HOMES.values():
        for cl in home["clients"]:
            ok, out = ping(cl, TARGET6)
            c.expect(ok, f"{cl} ping6 {TARGET6}: {last(out)}")
            ok, out = ping(cl, TARGET4)
            c.expect(ok, f"{cl} ping {TARGET4} (IPv4 through CLAT): {last(out)}")
        cl = home["clients"][0]
        dns = SITES[home["primary"]]["dns64"]
        _, out = dx(cl, f"dig +short +time=3 AAAA internet.lab @{dns}")
        c.expect(TARGET_DNS64 in out, f"{cl} DNS64 {dns}: internet.lab AAAA -> {out.strip()!r}")
        _, out = dx(cl, "grep nameserver /etc/resolv.conf")
        c.log(f"{cl} resolv.conf: {' | '.join(out.strip().splitlines())}")


def check_source(c, home, site):
    """Each client of the home uses site as its source. The other prefix is
    deprecated, and the internet sees sources of that site."""
    for cl in home["clients"]:
        addrs = client_addrs(cl)
        c.log(f"{cl} addresses (addr, deprecated): {addrs}")
        c.expect(preferred(addrs, site), f"{cl} {site} address is preferred")
        c.expect(deprecated_or_gone(addrs, OTHER[site]), f"{cl} {OTHER[site]} address is deprecated or gone")
        src = route_src(cl)
        c.expect(site_of(src) == site, f"{cl} ip -6 route get {TARGET6}: src {src} (site {site_of(src)})")
    cl = home["clients"][0]
    src, raw = seen_source(cl, TARGET6)
    c.expect(site_of(src) == site, f"internet sees IPv6 of {cl} from {src} (site {site_of(src)})")
    c.log(f"tcpdump: {raw}")
    src, raw = seen_source(cl, TARGET4)
    c.expect(pool4_site(src) == site, f"internet sees IPv4 of {cl} from {src} (NAT64 pool of {pool4_site(src)})")
    c.log(f"tcpdump: {raw}")


def t_source_prefix(c):
    """Clients use the prefix of their primary site: home 1 MUC, home 2 VIE."""
    for home in HOMES.values():
        st = ap_status(home["ap"])
        c.log(f"{home['ap']} status: {st['raw']}")
        c.expect(st.get("effective") == home["primary"],
                 f"{home['ap']} effective primary {st.get('effective')} (want {home['primary']})")
        check_source(c, home, home["primary"])


def t_inbound_standby(c):
    """The internet reaches each client on its standby prefix (ICMP and TCP)."""
    for home in HOMES.values():
        standby = OTHER[home["primary"]]
        for cl in home["clients"]:
            addr = client_addrs(cl).get(standby, (None,))[0]
            if not c.expect(addr is not None, f"{cl} has a {standby} (standby) address {addr}"):
                continue
            rc, out = run(inet_argv(f"ping -6 -c 3 -W 2 {addr}"), 40)
            c.expect(rc == 0, f"internet -> {cl} [{addr}] ping: {last(out)}")
        cl = home["clients"][0]
        addr = client_addrs(cl).get(standby, (None,))[0]
        if addr:
            dx(cl, "(timeout 30 socat TCP6-LISTEN:8080,reuseaddr SYSTEM:'echo hello-from-standby' >/dev/null 2>&1 &)")
            time.sleep(2)
            _, out = run(inet_argv(f"timeout 10 socat -T 5 - TCP6:[{addr}]:8080 </dev/null"), 30)
            c.expect("hello-from-standby" in out, f"internet -> {cl} [{addr}]:8080 TCP: {out.strip()!r}")


def t_failover(c, site):
    """The primary site of a home fails. Its AP swaps the prefix states,
    rejects the dead prefix with ICMPv6 code 5, moves IPv4, and later stops
    sending the dead prefix. The other home is not affected."""
    home = home_with_primary(site)
    other_home = next(h for h in HOMES.values() if h is not home)
    ap, cl, backup = home["ap"], home["clients"][0], OTHER[site]
    before = client_addrs(cl)
    c.log(f"{cl} addresses before: {before}")
    c.log(f"{ap} IPv4 default before: dev {route4_dev(ap)}")

    c.log(f"cut the uplinks of {SITES[site]['gws']} on the internet node at {time.strftime('%H:%M:%S')}")
    set_site_links(site, "down")
    t0 = time.time()

    st = wait_status(ap, lambda s: s.get("effective") == backup, FAILOVER_TIMEOUT)
    c.expect(st is not None, f"{ap} detected the failure after {int(time.time() - t0)} s")
    st = st or ap_status(ap)
    c.log(f"{ap} status: {st['raw']}")
    dead_iface = st["sites"].get(site, {}).get("iface")
    live_iface = st["sites"].get(backup, {}).get("iface")

    ok = wait_for(lambda: all(preferred(a, backup) and deprecated_or_gone(a, site)
                              for a in map(client_addrs, home["clients"])), 120, step=5)
    c.expect(ok, f"clients of {ap} deprecated {site} and prefer {backup} after {int(time.time() - t0)} s")
    check_source(c, home, backup)

    ok, out = ping(cl, TARGET6)
    c.expect(ok, f"{cl} ping6 {TARGET6} through {backup}: {last(out)}")
    ok, out = ping(cl, TARGET4)
    c.expect(ok, f"{cl} ping {TARGET4} after IPv4 failover: {last(out)}")
    dev = route4_dev(ap)
    c.expect(dev == live_iface, f"{ap} IPv4 default via {dev} (want {live_iface}, dead tunnel {dead_iface})")

    dead_addr = before.get(site, (None,))[0]
    if c.expect(dead_addr is not None, f"{cl} had a {site} address before: {dead_addr}"):
        p = subprocess.Popen(["sudo", "docker", "exec", f"clab-{LAB}-{cl}", "sh", "-c",
                              "timeout 20 tcpdump -lnni lan -c 1 'icmp6 and ip6[40] == 1 and ip6[41] == 5'"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(3)
        _, pout = ping(cl, TARGET6, extra=f"-I {dead_addr}", count=3)
        out, _ = p.communicate(timeout=40)
        c.expect("1 packet captured" in out,
                 f"{cl} ping from dead {dead_addr} gets ICMPv6 type 1 code 5 (policy fail)")
        c.log(f"ping: {' | '.join(pout.strip().splitlines()[-3:])}")
        c.log(f"tcpdump: {' | '.join(out.strip().splitlines())}")
    _, out = vm(ap, "ip6tables -S parker_as")
    c.expect(f"-s {st['sites'].get(site, {}).get('range6')} -j REJECT" in out,
             f"{ap} rejects the dead {site} prefix: {' | '.join(out.strip().splitlines())}")

    ost = ap_status(other_home["ap"])
    c.expect(ost.get("effective") == other_home["primary"],
             f"{other_home['ap']} keeps its primary {other_home['primary']}: {ost.get('effective')}")
    ok, out = ping(other_home["clients"][0], TARGET6)
    c.expect(ok, f"{other_home['clients'][0]} ping6 still works: {last(out)}")

    st = wait_status(ap, lambda s: s["sites"].get(site, {}).get("ra") == "off", WITHDRAW_TIMEOUT)
    c.expect(st is not None, f"{ap} stopped sending the {site} prefix after {int(time.time() - t0)} s")
    _, out = vm(ap, "ps | grep [u]radvd")
    c.log(f"{ap} uradvd: {' | '.join(out.strip().splitlines())}")


def t_recovery(c, site):
    """The failed site comes back. The AP returns to the configured primary."""
    home = home_with_primary(site)
    ap = home["ap"]
    c.log(f"restore the uplinks of {SITES[site]['gws']} at {time.strftime('%H:%M:%S')}")
    set_site_links(site, "up")
    t0 = time.time()
    st = wait_status(ap, lambda s: s.get("effective") == site and len(s["sites"]) == 2 and
                     all(x["state"] == "live" and x["ra"] == "on" for x in s["sites"].values()),
                     FAILOVER_TIMEOUT)
    c.expect(st is not None, f"{ap} back on primary {site} after {int(time.time() - t0)} s")
    c.log(f"{ap} status: {(st or ap_status(ap))['raw']}")
    ok = wait_for(lambda: all(preferred(a, site) and deprecated_or_gone(a, OTHER[site]) and OTHER[site] in a
                              for a in map(client_addrs, home["clients"])), 180, step=5)
    c.expect(ok, f"clients of {ap} prefer {site} and have {OTHER[site]} as standby after {int(time.time() - t0)} s")
    check_source(c, home, site)
    _, out = vm(ap, "ip6tables -S parker_as")
    c.expect("REJECT" not in out, f"{ap} no reject rule left: {' | '.join(out.strip().splitlines())}")
    ok, out = ping(home["clients"][0], TARGET4)
    c.expect(ok, f"{home['clients'][0]} IPv4 after recovery: {last(out)}")


TESTS = [
    ("ready", t_ready),
    ("normal", t_normal),
    ("source-prefix", t_source_prefix),
    ("inbound-standby", t_inbound_standby),
    ("failover-vie", lambda c: t_failover(c, "vie")),
    ("recovery-vie", lambda c: t_recovery(c, "vie")),
    ("failover-muc", lambda c: t_failover(c, "muc")),
    ("recovery-muc", lambda c: t_recovery(c, "muc")),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results", default=os.path.join(ROOT, "results"))
    parser.add_argument("tests", nargs="*")
    args = parser.parse_args()
    table = dict(TESTS)
    names = args.tests or [n for n, _ in TESTS]
    unknown = [n for n in names if n not in table]
    if unknown:
        parser.error(f"unknown test(s): {unknown}")
    os.makedirs(args.results, exist_ok=True)

    all_ok = True
    skip = None
    for i, name in enumerate(names, 1):
        c = Check(name)
        if skip:
            c.expect(False, f"skipped: {skip}")
        else:
            try:
                table[name](c)
            except Exception as e:  # a crash is a failure with evidence
                c.expect(False, f"exception: {e!r}")
            if name == "ready" and not c.ok:
                skip = "lab not ready"
        with open(os.path.join(args.results, f"test-{i:02d}-{name}.json"), "w") as f:
            json.dump({"name": name, "pass": c.ok, "evidence": c.evidence}, f, indent=2)
        print(f"== {name}: {'PASS' if c.ok else 'FAIL'}", flush=True)
        all_ok = all_ok and c.ok
    for site in SITES:  # leave the links up whatever happened
        set_site_links(site, "up")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
