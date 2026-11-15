#!/usr/bin/env python3
"""Tests for the multi-PoP active/standby lab (clab name ffmuc-mp-as).

Usage: tests/multipop_as.py [--results DIR] [TEST ...]
Tests: see TESTS at the end, in that order. Without TEST: all.

Each test prints its evidence and writes DIR/test-NN-<test>.json with
{"name", "pass", "evidence": [...], "metrics": {...}}. The metrics hold the
measured downtimes: "ap" (seconds, seen on the AP status) and "clients"
(per client, seen in the client traffic, see tests/clientmon.sh).
Exit 0 only when all selected tests pass.
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
# The second client of each home uses dhcpcd for IPv6, the first the kernel.
HOMES = {
    "home1": {"ap": "ap-1", "clients": ["client-1", "client-2"], "primary": "muc"},
    "home2": {"ap": "ap-2", "clients": ["client-3", "client-4"], "primary": "vie"},
}
# AP-3: new firmware, home 1, meshes with AP-1. Its client roams.
AP3 = {"ap": "ap-3", "clients": ["client-5"], "primary": "muc"}
# AP-4: old firmware, home 2. The broker gives it one site.
OLD = {"ap": "ap-4", "clients": ["client-6"], "site": "vie"}
OTHER = {"muc": "vie", "vie": "muc"}
# The broker plane (multipop/brokers), as the wgkex setup in production:
# stateless brokers, one EMQX cluster, one haproxy per site on broker.lab.
PLANE = {
    "brokers": {"broker-muc-1": "198.51.100.67", "broker-muc-2": "198.51.100.68",
                "broker-vie-1": "198.51.100.83", "broker-vie-2": "198.51.100.84"},
    "emqx": ["emqx-muc-1", "emqx-muc-2", "emqx-vie-1", "emqx-vie-2"],
    "lbs": ["lb-muc", "lb-vie"],
}
BROKER_LAB = "198.51.100.100"
MQTT_LAB = "198.51.100.101"
# MQTT keepalive 5 s and EMQX dist_net_ticktime 10 s, plus slack.
PLANE_SETTLE = int(os.environ.get("PLANE_SETTLE", "30"))

# Probe every 1 s, 3 misses per pgw, 2 pgws per site, plus slack.
FAILOVER_TIMEOUT = int(os.environ.get("FAILOVER_TIMEOUT", "120"))
# 3 hits, a fresh handshake, 10 s dwell, plus slack.
RECOVERY_TIMEOUT = int(os.environ.get("RECOVERY_TIMEOUT", "300"))
# DEAD_KEEP (180 s) in parker-as.lua plus slack.
WITHDRAW_TIMEOUT = int(os.environ.get("WITHDRAW_TIMEOUT", "300"))
# The last RA with the dead prefix had valid lifetime 600 s.
EXPIRE_TIMEOUT = int(os.environ.get("EXPIRE_TIMEOUT", "900"))
READY_TIMEOUT = int(os.environ.get("READY_TIMEOUT", "1800"))
# The old pgw drops the /63 of the node this many s after the switch.
UNROUTE_TIMEOUT = int(os.environ.get("UNROUTE_TIMEOUT", "15"))
# Upper limits for the longest gap in the client traffic (s). They catch a
# return to slow failover; the measured values are in the metrics.
GAP_PGW = float(os.environ.get("GAP_PGW", "30"))
GAP_SITE = float(os.environ.get("GAP_SITE", "60"))
GAP_BACK = float(os.environ.get("GAP_BACK", "10"))
RESULTS = None


class Check:
    def __init__(self, name):
        self.name = name
        self.ok = True
        self.evidence = []
        self.metrics = {}

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
        m = re.match(r"(primary_site|active)=(\S+)", line)
        if m:
            st[m.group(1)] = m.group(2)
        m = re.match(r"site (\S+) (up|down) (.*)", line)
        if m:
            site = dict(kv.split("=", 1) for kv in m.group(3).split() if "=" in kv)
            site["state"] = m.group(2)
            st["sites"][m.group(1)] = site
    return st


def net63(range6):
    return range6.replace("/64", "/63") if range6 else None


def wait_status(ap, pred, timeout, step=1):
    def poll():
        st = ap_status(ap)
        return st if pred(st) else None
    return wait_for(poll, timeout, step)


def client_v4(client):
    """The DHCPv4 address of a client, or None. An IPv4LL (169.254/16)
    address from dhcpcd does not count."""
    _, out = dx(client, "ip -4 -o addr show dev lan scope global")
    for a in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)/", out):
        if not a.startswith("169.254."):
            return a
    return None


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


def set_link(gw, state):
    dx("internet", f"ip link set {gw} {state}")


def set_site_links(site, state):
    for gw in SITES[site]["gws"]:
        set_link(gw, state)


def all_up(st, primary):
    return st.get("active") == primary and len(st["sites"]) == 2 and \
        all(s["state"] == "up" and s.get("ra") == "on" for s in st["sites"].values())


def pmtu_ping(client, dst, src=None, size=1452):
    """DF ping with size bytes of payload. Return (ok, mtu reported, output)."""
    six = "-6 " if ":" in dst else ""
    frm = f"-I {src} " if src else ""
    rc, out = dx(client, f"ping {six}-M do -s {size} {frm}-c 3 -W 2 {dst}", timeout=30)
    m = re.search(r"mtu[=: ]+(\d+)", out, re.I)
    return rc == 0, (int(m.group(1)) if m else None), out


def settle(c):
    """Wait until every new-firmware AP has both sites up and is on its primary."""
    aps = list(HOMES.values()) + [AP3]
    ok = wait_for(lambda: all(all_up(ap_status(h["ap"]), h["primary"]) for h in aps),
                  RECOVERY_TIMEOUT, step=10)
    c.expect(ok, "start state: all APs up and on their primary site")


def home_with_primary(site):
    return next(h for h in HOMES.values() if h["primary"] == site)


# ---------------------------------------------------------------- tests

def t_ready(c):
    """The lab is up: each AP has two live sites and the right primary, and
    each client has an address from both sites and a DHCPv4 lease. noderoute
    starts DHCPv4 only after the IPv4 route of the AP is up, so tests that
    start before that see no IPv4 at all."""
    def ready():
        for home in list(HOMES.values()) + [AP3]:
            if not all_up(ap_status(home["ap"]), home["primary"]):
                return False
            for cl in home["clients"]:
                if set(client_addrs(cl)) != {"muc", "vie"} or not client_v4(cl):
                    return False
        return all(set(client_addrs(cl)) == {OLD["site"]} and client_v4(cl) for cl in OLD["clients"])

    t0 = time.time()
    c.expect(wait_for(ready, READY_TIMEOUT, step=20), f"lab ready after {int(time.time() - t0)} s")
    for home in list(HOMES.values()) + [AP3]:
        st = ap_status(home["ap"])
        c.log(f"{home['ap']} status: {st['raw']}")
        c.expect(st.get("primary_site") == home["primary"],
                 f"{home['ap']} primary_site from broker = {st.get('primary_site')} (want {home['primary']})")
        for cl in home["clients"]:
            c.log(f"{cl} addresses: {client_addrs(cl)} IPv4 {client_v4(cl)}")


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


def ra_prefixes(client, wait_ms=10000):
    """The RAs a client receives in wait_ms: a list of {site: preferred}."""
    _, out = dx(client, f"rdisc6 -m -w {wait_ms} lan", timeout=wait_ms // 1000 + 20)
    ras, cur, site = [], None, None
    for line in out.splitlines():
        if "Hop limit" in line:
            cur = {}
            ras.append(cur)
        m = re.search(r"Prefix\s+:\s+([0-9a-f:]+)/64", line)
        if m and cur is not None:
            site = site_of(m.group(1))
            cur[site] = None
        m = re.search(r"Pref\. time\s+:\s+(\d+)", line)
        if m and cur is not None and site in cur:
            cur[site] = int(m.group(1))
    return ras


def t_ra_single(c):
    """One uradvd per AP sends both prefixes in every RA: the primary with a
    preferred lifetime, the standby with preferred lifetime 0. No address
    changes state for 60 s, with kernel SLAAC and with dhcpcd."""
    for home in HOMES.values():
        ap, primary = home["ap"], home["primary"]
        _, out = vm(ap, "pidof uradvd")
        c.expect(len(out.split()) == 1, f"{ap} runs one uradvd (pids: {out.strip()!r})")
        _, out = vm(ap, "cat /tmp/parker-as/ra-state")
        c.log(f"{ap} ra-state: {' | '.join(out.strip().splitlines())}")
        for cl in home["clients"]:
            ras = ra_prefixes(cl)
            good = [ra for ra in ras if set(ra) == {"muc", "vie"}
                    and ra[primary] and ra[OTHER[primary]] == 0]
            c.expect(ras and len(good) == len(ras),
                     f"{cl}: {len(good)}/{len(ras)} RAs have both prefixes, {primary} preferred, "
                     f"{OTHER[primary]} preferred 0: {ras}")
    bad = set()
    for _ in range(12):
        for home in HOMES.values():
            for cl in home["clients"]:
                a = client_addrs(cl)
                if not preferred(a, home["primary"]):
                    bad.add(f"{cl}: {home['primary']} not preferred")
                if OTHER[home["primary"]] not in a:
                    bad.add(f"{cl}: {OTHER[home['primary']]} missing")
        time.sleep(5)
    c.expect(not bad, f"60 s: primary preferred and standby present on all clients {sorted(bad)}")


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
        c.expect(st.get("active") == home["primary"],
                 f"{home['ap']} active site {st.get('active')} (want {home['primary']})")
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


def code5_from(c, cl, addr, extra_cmd=None):
    """Ping TARGET6 from addr on cl. Expect ICMPv6 type 1 code 5 back."""
    p = subprocess.Popen(["sudo", "docker", "exec", f"clab-{LAB}-{cl}", "sh", "-c",
                          "timeout 20 tcpdump -lnni lan -c 1 'icmp6 and ip6[40] == 1 and ip6[41] == 5'"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(3)
    _, pout = ping(cl, TARGET6, extra=f"-I {addr}", count=3)
    out, _ = p.communicate(timeout=40)
    c.expect("1 packet captured" in out, f"{cl} ping from {addr} gets ICMPv6 type 1 code 5 (policy fail)")
    c.log(f"ping: {' | '.join(pout.strip().splitlines()[-3:])}")
    c.log(f"tcpdump: {' | '.join(out.strip().splitlines())}")


def time_to(fn, timeout, step=2):
    """Seconds until fn() is true, or None."""
    t0 = time.time()
    return int(time.time() - t0) if wait_for(fn, timeout, step) else None


# ------------------------------------------------- client traffic monitor

MONSRV = f"{LAB}-monsrv"


def mon_server(start=True):
    """The stream and HTTP server of the monitor, in the internet netns."""
    run(["sudo", "docker", "rm", "-f", MONSRV])
    if start:
        rc, out = run(["sudo", "docker", "run", "-d", "--rm", "--name", MONSRV,
                       "--net", f"container:clab-{LAB}-internet",
                       "-v", f"{ROOT}/tests/monsrv.py:/monsrv.py:ro",
                       "--entrypoint", "python3", "ffmuc-lab:toolbox", "/monsrv.py"])
        print(f"monitor server: rc={rc} {out.strip()}", flush=True)


def mon_start(clients):
    """Start the traffic monitor on each client, then wait for a baseline."""
    for cl in clients:
        run(["sudo", "docker", "cp", os.path.join(ROOT, "tests", "clientmon.sh"),
             f"clab-{LAB}-{cl}:/tmp/clientmon.sh"])
        run(["sudo", "docker", "exec", "-d", f"clab-{LAB}-{cl}",
             "sh", "/tmp/clientmon.sh", "start", TARGET6, TARGET4])
    time.sleep(5)


def _sections(out):
    sec, cur = {}, None
    for line in out.splitlines():
        if line.startswith("=== "):
            cur = sec.setdefault(line[4:].strip(), [])
        elif cur is not None:
            cur.append(line)
    return sec


def _float(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _max_gap(times, start, stop):
    """The longest time with no data between start and stop, in ms."""
    if not times:
        return round((stop - start) * 1000)
    edges = sorted(times) + [stop]
    return round(max(b - a for a, b in zip(edges, edges[1:])) * 1000)


def mon_parse(out, event):
    """Metrics of one client: the longest gap with no ping replies (ms), the
    lost pings, if the long TCP stream survived, and the time from the event
    until a new connection works (s, 0 when no connection failed)."""
    sec = _sections(out)
    start = _float((sec.get("start") or [""])[0])
    stop = _float((sec.get("stop") or [""])[0])
    if start is None or stop is None:
        return {"error": "no monitor data"}
    m = {"seconds": round(stop - start, 1)}
    for f in ("6", "4"):
        replies, sent, got = [], 0, 0
        for line in sec.get(f"ping{f}.log", []):
            r = re.match(r"\[(\d+\.\d+)\] \d+ bytes from", line)
            if r:
                replies.append(float(r.group(1)))
            r = re.match(r"(\d+) packets transmitted, (\d+) received", line)
            if r:
                sent, got = sent + int(r.group(1)), got + int(r.group(2))
        m[f"ping{f}_max_gap_ms"] = _max_gap([t for t in replies if t >= start + 2], start + 2, stop)
        m[f"ping{f}_sent"] = sent
        m[f"ping{f}_lost"] = sent - got
        m[f"ping{f}_back"] = any(t > event for t in replies)
        data, end = [], None
        for line in sec.get(f"tcp{f}.log", []):
            parts = line.split(None, 1)
            t = _float(parts[0]) if parts else None
            if t is None:
                continue
            if len(parts) > 1 and parts[1].startswith("END"):
                end = end or t
            elif len(parts) > 1 and _float(parts[1]) is not None:
                data.append(t)
        m[f"tcp{f}_survived"] = bool(data) and (end is None or end >= stop) and max(data) > stop - 2
        m[f"tcp{f}_max_gap_ms"] = _max_gap(data, data[0] if data else start, min(end or stop, stop))
        fail_at, back = None, None
        for line in sec.get(f"curl{f}.log", []):
            parts = line.split()
            t = _float(parts[0]) if parts else None
            if t is None or t < event or len(parts) < 2:
                continue
            if parts[1] == "fail" and fail_at is None:
                fail_at = t
            elif parts[1] == "ok" and fail_at is not None and back is None:
                back = t + 1  # the curl was ok within its 1 s limit
        m[f"new_conn{f}_s"] = 0 if fail_at is None else (round(back - event, 1) if back else None)
    return m


def mon_stop(c, case, clients, event):
    """Stop the monitor, keep the raw logs, and add the metrics to c."""
    result = {}
    for cl in clients:
        _, out = dx(cl, "sh /tmp/clientmon.sh stop", timeout=60)
        if RESULTS:
            with open(os.path.join(RESULTS, f"mon-{c.name}-{case}-{cl}.log"), "w") as f:
                f.write(out)
        m = mon_parse(out, event)
        result[cl] = m
        c.log(f"{case} {cl} client traffic: {m}")
    c.metrics.setdefault("clients", {})[case] = result
    return result


def expect_traffic(c, case, result, max_gap=None, families=("6", "4")):
    """Traffic came back for every client; optionally the longest ping gap
    is below max_gap s."""
    for cl, m in result.items():
        for f in families:
            ip = "IPv6" if f == "6" else "IPv4"
            c.expect(m.get(f"ping{f}_back") and m.get(f"new_conn{f}_s") is not None,
                     f"{case} {cl} {ip}: traffic back, longest gap {m.get(f'ping{f}_max_gap_ms')} ms, "
                     f"new connection after {m.get(f'new_conn{f}_s')} s")
            if max_gap is not None and m.get(f"ping{f}_max_gap_ms") is not None:
                c.expect(m[f"ping{f}_max_gap_ms"] <= max_gap * 1000,
                         f"{case} {cl} {ip}: longest gap {m[f'ping{f}_max_gap_ms']} ms <= {max_gap} s")


def ap_metric(c, key, value):
    c.metrics.setdefault("ap", {})[key] = value


def inbound_time(addr, timeout=60):
    """Seconds until the internet reaches addr with ping, or None."""
    return time_to(lambda: run(inet_argv(f"ping -6 -c 1 -W 1 {addr}"), 20)[0] == 0, timeout, step=1)


def t_site_failure(c, site, long_outage=False):
    """All pgws of the primary site of a home fail. The AP swaps the prefix
    states, rejects the dead prefix with ICMPv6 code 5, moves IPv4, and
    later stops sending the dead prefix. The other home is not affected.
    long_outage: also wait until the dead address expired on the clients."""
    settle(c)
    home = home_with_primary(site)
    other_home = next(h for h in HOMES.values() if h is not home)
    ap, cl, backup = home["ap"], home["clients"][0], OTHER[site]
    before = client_addrs(cl)
    c.log(f"{cl} addresses before: {before}")
    c.log(f"{ap} IPv4 default before: dev {route4_dev(ap)}")
    clients = home["clients"] + other_home["clients"]
    mon_start(clients)

    c.log(f"cut the uplinks of {SITES[site]['gws']} on the internet node at {time.strftime('%H:%M:%S')}")
    set_site_links(site, "down")
    t0 = time.time()

    st = wait_status(ap, lambda s: s.get("active") == backup and
                     s["sites"].get(site, {}).get("state") == "down", FAILOVER_TIMEOUT)
    ap_metric(c, "site_down_s", round(time.time() - t0, 1) if st else None)
    c.expect(st is not None, f"{ap} marked {site} down after {int(time.time() - t0)} s")
    st = st or ap_status(ap)
    c.log(f"{ap} status: {st['raw']}")
    dead_iface = st["sites"].get(site, {}).get("iface")
    live_iface = st["sites"].get(backup, {}).get("iface")

    ok = wait_for(lambda: all(preferred(a, backup) and deprecated_or_gone(a, site)
                              for a in map(client_addrs, home["clients"])), 120, step=5)
    ap_metric(c, "clients_swapped_s", round(time.time() - t0, 1) if ok else None)
    c.expect(ok, f"clients of {ap} deprecated {site} and prefer {backup} after {int(time.time() - t0)} s")

    t6 = time_to(lambda: ping(cl, TARGET6, count=1)[0], 60, step=1)
    c.expect(t6 is not None, f"{cl} IPv6 through {backup} works (after {t6} s more)")
    t4 = time_to(lambda: ping(cl, TARGET4, count=1)[0], 60, step=1)
    c.expect(t4 is not None, f"{cl} IPv4 through the CLAT of {backup} works (after {t4} s more)")
    addr = client_addrs(cl).get(backup, (None,))[0]
    ti = inbound_time(addr) if addr else None
    ap_metric(c, "inbound_after_switch_s", None if ti is None else round(time.time() - t0, 1))
    c.expect(ti is not None, f"internet -> {cl} [{addr}] ({backup}) works after the switch")
    time.sleep(5)
    result = mon_stop(c, "site-failover", clients, t0)
    expect_traffic(c, "site-failover", {x: result[x] for x in home["clients"]}, GAP_SITE)
    expect_traffic(c, "site-failover other home", {x: result[x] for x in other_home["clients"]}, GAP_BACK)
    check_source(c, home, backup)
    dev = route4_dev(ap)
    c.expect(dev == live_iface, f"{ap} IPv4 default via {dev} (want {live_iface}, dead tunnel {dead_iface})")

    dead_addr = before.get(site, (None,))[0]
    if c.expect(dead_addr is not None, f"{cl} had a {site} address before: {dead_addr}"):
        code5_from(c, cl, dead_addr)
    _, out = vm(ap, "ip6tables -S parker_src")
    c.expect(f"-s {net63(st['sites'].get(site, {}).get('range6'))} -j REJECT" in out,
             f"{ap} rejects the dead {site} /63: {' | '.join(out.strip().splitlines())}")

    ost = ap_status(other_home["ap"])
    c.expect(ost.get("active") == other_home["primary"],
             f"{other_home['ap']} keeps its active site {other_home['primary']}: {ost.get('active')}")
    ok, out = ping(other_home["clients"][0], TARGET6)
    c.expect(ok, f"{other_home['clients'][0]} ping6 still works: {last(out)}")

    st = wait_status(ap, lambda s: s["sites"].get(site, {}).get("ra") == "off", WITHDRAW_TIMEOUT)
    c.expect(st is not None, f"{ap} stopped sending the {site} prefix after {int(time.time() - t0)} s")
    if long_outage:
        gone = wait_for(lambda: all(site not in client_addrs(x) for x in home["clients"]),
                        EXPIRE_TIMEOUT, step=20)
        c.expect(gone, f"the {site} address expired on all clients of {ap} after {int(time.time() - t0)} s")
        _, out = vm(ap, "ip6tables -S parker_src")
        c.expect("REJECT --reject-with icmp6-policy-fail" in out and net63(st and st['sites'][site]['range6']) in out,
                 f"{ap} reject rule still active after the long outage")


def t_recovery(c, site):
    """The failed site comes back. The AP returns to the configured primary
    after 3 hits, a fresh handshake and the dwell (no hold-down). The clients
    get the prefix back, also after a long outage in which the address
    expired. The switch-back does not stop client traffic."""
    home = home_with_primary(site)
    ap = home["ap"]
    mon_start(home["clients"])
    c.log(f"restore the uplinks of {SITES[site]['gws']} at {time.strftime('%H:%M:%S')}")
    set_site_links(site, "up")
    t0 = time.time()
    st = wait_status(ap, lambda s: s["sites"].get(site, {}).get("state") == "up", RECOVERY_TIMEOUT)
    t_up = round(time.time() - t0, 1)
    c.expect(st is not None, f"{ap} marked {site} up after {t_up} s (3 hits, fresh handshake, dwell)")
    st = wait_status(ap, lambda s: all_up(s, site), RECOVERY_TIMEOUT)
    t_back = round(time.time() - t0, 1)
    ap_metric(c, "site_up_s", t_up)
    ap_metric(c, "switch_back_s", t_back if st else None)
    c.expect(st is not None, f"{ap} back on primary {site} after {t_back} s")
    c.expect(t_back - t_up < 15, f"no hold-down before the switch-back: {round(t_back - t_up, 1)} s")
    c.log(f"{ap} status: {(st or ap_status(ap))['raw']}")
    ok = wait_for(lambda: all(preferred(a, site) and deprecated_or_gone(a, OTHER[site]) and OTHER[site] in a
                              for a in map(client_addrs, home["clients"])), 180, step=2)
    ap_metric(c, "clients_swapped_s", round(time.time() - t0, 1) if ok else None)
    c.expect(ok, f"clients of {ap} prefer {site} and have {OTHER[site]} as standby after {int(time.time() - t0)} s")
    time.sleep(10)
    result = mon_stop(c, "switch-back", home["clients"], t0)
    expect_traffic(c, "switch-back", result, GAP_BACK)
    check_source(c, home, site)
    _, out = vm(ap, "ip6tables -S parker_src")
    c.expect(f"-s {net63(st and st['sites'][site]['range6'])} -j RETURN" in out,
             f"{ap} accepts {site} again: {' | '.join(out.strip().splitlines())}")
    ok, out = ping(home["clients"][0], TARGET4)
    c.expect(ok, f"{home['clients'][0]} IPv4 after recovery: {last(out)}")


def pgw_routes(gw, net):
    """Lines of the /63 route of a node on a pgw."""
    _, out = vm(f"gateway-{gw}", f"ip -6 route show {net}", 20)
    return [line for line in out.splitlines() if line.startswith(net.split("/")[0])]


def set_plane(ctr, state):
    """Cut or restore the DC LAN link of a broker plane container."""
    dx(ctr, f"ip link set eth1 {state}")


def plane_health():
    """Health of the broker plane, seen from the internet node and EMQX."""
    _, out = dx("emqx-muc-1", "emqx ctl cluster status")
    running = sorted(set(re.findall(r"emqx@[0-9.]+", out.split("stopped_nodes")[0])))
    probes = " ; ".join(
        f"echo {n} $(curl -s -o /dev/null -m 2 -w '%{{http_code}}' http://{ip}:5000/api/v3/lab/health)"
        for n, ip in PLANE["brokers"].items())
    probes += f" ; echo broker.lab $(curl -s -o /dev/null -m 2 -w '%{{http_code}}' http://{BROKER_LAB}/haproxy-health)"
    _, out = run(inet_argv(probes), 60)
    http = dict(line.split() for line in out.splitlines() if len(line.split()) == 2)
    return running, http


def reporters(since):
    """The brokers that logged a switch report since the time stamp."""
    names = []
    for n in PLANE["brokers"]:
        _, out = run(["sudo", "docker", "logs", "--since", since, f"clab-{LAB}-{n}"])
        names += [n] * out.count("lab switch:")
    return names


def t_plane(c):
    """The broker plane is complete: 4 EMQX nodes in one cluster, 4 healthy
    brokers, broker.lab answers, and each gateway reaches mqtt.lab over the
    gateway VPN (not over its uplink)."""
    running, http = plane_health()
    c.expect(len(running) == 4, f"EMQX cluster running nodes: {running}")
    for n in list(PLANE["brokers"]) + ["broker.lab"]:
        c.expect(http.get(n) == "200", f"{n} health: {http.get(n)}")
    for gw in SITES["muc"]["gws"] + SITES["vie"]["gws"]:
        _, out = vm(f"gateway-{gw}", f"ip route get {MQTT_LAB}", 20)
        c.expect("dev vpn" in out, f"{gw} reaches mqtt.lab: {last(out)}")


def pgw_switch(c, home_key, case):
    """One pgw of the primary site of a home fails. The AP moves the tunnel to
    the other pgw of the same site after 3 s. The prefix stays preferred all
    the time. After the handshake the AP reports the switch through
    broker.lab, and the old pgw drops the /63 at once. Client traffic is
    measured. The cut pgw comes back at the end."""
    settle(c)
    home = HOMES[home_key]
    other = next(h for k, h in HOMES.items() if k != home_key)
    ap, cl, site = home["ap"], home["clients"][0], home["primary"]
    st = ap_status(ap)
    old = st["sites"][site].get("pgw")
    net = net63(st["sites"][site].get("range6"))
    c.log(f"{ap} status: {st['raw']}")
    if not c.expect(old in SITES[site]["gws"], f"{ap} uses pgw {old} for {site}"):
        return
    c.log(f"{old} routes {net}: {pgw_routes(old, net)}")
    clients = home["clients"] + other["clients"]
    mon_start(clients)
    since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    c.log(f"cut the uplink of {old} at {time.strftime('%H:%M:%S')}")
    set_link(old, "down")
    t0 = time.time()
    not_preferred = set()
    switched = new = None
    try:
        while time.time() - t0 < FAILOVER_TIMEOUT and switched is None:
            s = ap_status(ap)
            if s["sites"][site]["state"] != "up":
                not_preferred.add(f"{ap} marked {site} {s['sites'][site]['state']}")
            if s["sites"][site].get("pgw") not in (old, "?") and s["sites"][site].get("fresh") == "true":
                switched, new = round(time.time() - t0, 1), s["sites"][site].get("pgw")
                c.log(f"{ap} switched to {new} after {switched} s: {s['raw']}")
            time.sleep(0.5)
        ap_metric(c, "intra_site_switch_s", switched)
        c.expect(switched is not None, f"{ap} moved wg tunnel of {site} to the other pgw ({switched} s)")
        gone = time_to(lambda: not pgw_routes(old, net), UNROUTE_TIMEOUT + 30, step=1)
        unroute = None if gone is None else round(time.time() - t0 - switched, 1) if switched else None
        ap_metric(c, "old_pgw_unroute_s", unroute)
        c.expect(gone is not None and unroute is not None and unroute <= UNROUTE_TIMEOUT,
                 f"{old} dropped {net} {unroute} s after the switch (limit {UNROUTE_TIMEOUT} s)")
        st = wait_status(ap, lambda s: s["sites"][site].get("report") == "none", UNROUTE_TIMEOUT)
        c.expect(st is not None, f"{ap} report to broker.lab done: {(st or ap_status(ap))['raw']}")
        c.log(f"brokers that took the report: {reporters(since)}")
        if new:
            c.log(f"{new} routes {net}: {pgw_routes(new, net)}")
        a = client_addrs(cl)[site][0]
        ti = inbound_time(a)
        ap_metric(c, "inbound_after_switch_s", None if ti is None else round(time.time() - t0, 1))
        c.expect(ti is not None, f"internet -> {cl} [{a}] through the new pgw")
        for x in home["clients"]:
            if not preferred(client_addrs(x), site):
                not_preferred.add(x)
        time.sleep(5)
        result = mon_stop(c, case, clients, t0)
        expect_traffic(c, case, {x: result[x] for x in home["clients"]}, GAP_PGW)
        expect_traffic(c, f"{case} other home", {x: result[x] for x in other["clients"]}, GAP_BACK)
        c.expect(not not_preferred, f"{site} prefix stayed preferred and the site stayed up {sorted(not_preferred)}")
        check_source(c, home, site)
    finally:
        set_link(old, "up")
        c.log(f"restored the uplink of {old}")


def t_pgw_failure(c, home_key):
    pgw_switch(c, home_key, "pgw-switch")


def t_plane_failure(c, ctr, home_key="home1"):
    """One part of the broker plane fails (a broker, an EMQX node or the
    haproxy of a site). Then a pgw fails: the report still reaches a broker,
    and the old pgw drops the /63 within the normal limit."""
    c.log(f"cut {ctr} at {time.strftime('%H:%M:%S')}")
    set_plane(ctr, "down")
    try:
        time.sleep(PLANE_SETTLE)
        running, http = plane_health()
        c.log(f"plane after the cut: EMQX {running}, health {http}")
        c.expect(http.get("broker.lab") == "200", f"broker.lab still answers with {ctr} down")
        pgw_switch(c, home_key, f"plane-{ctr}")
    finally:
        set_plane(ctr, "up")
        ok = wait_for(lambda: (lambda r, h: len(r) == 4 and all(v == "200" for v in h.values())
                               and len(h) == 5)(*plane_health()), 120, step=5)
        c.log(f"{ctr} restored, plane complete: {bool(ok)}")


def t_broker_down_pgw(c):
    """All brokers are down and a pgw fails. The node still moves to the
    other pgw of the site: every pgw has the peer already. The report waits
    until a broker is back."""
    settle(c)
    home = HOMES["home2"]
    ap, site = home["ap"], home["primary"]
    for n in PLANE["brokers"]:
        set_plane(n, "down")
    c.log(f"all brokers cut, plane health: {plane_health()[1]}")
    try:
        old = ap_status(ap)["sites"][site].get("pgw")
        if not c.expect(old in SITES[site]["gws"], f"{ap} uses pgw {old} for {site}"):
            return
        mon_start(home["clients"])
        set_link(old, "down")
        t0 = time.time()
        st = wait_status(ap, lambda s: s["sites"][site].get("pgw") not in (old, "?") and
                         s["sites"][site].get("fresh") == "true", FAILOVER_TIMEOUT)
        ap_metric(c, "intra_site_switch_s", round(time.time() - t0, 1) if st else None)
        c.expect(st is not None, f"{ap} moved {site} away from {old} with the brokers down "
                                 f"after {int(time.time() - t0)} s")
        st = st or ap_status(ap)
        c.log(f"{ap} status: {st['raw']}")
        c.expect(st["sites"][site]["state"] == "up", f"{site} stayed up")
        c.expect(st["sites"][site].get("report") == "pending", f"the report to the broker waits: "
                 f"report={st['sites'][site].get('report')}")
        time.sleep(15)
        result = mon_stop(c, "broker-down", home["clients"], t0)
        expect_traffic(c, "broker-down", result, GAP_PGW)
        for cl in home["clients"]:
            c.expect(preferred(client_addrs(cl), site), f"{cl} {site} address still preferred")
        set_link(old, "up")
    finally:
        for gw in SITES[site]["gws"]:
            set_link(gw, "up")
        for n in PLANE["brokers"]:
            set_plane(n, "up")
        c.log("brokers restored")
    st = wait_status(ap, lambda s: s["sites"][site].get("report") == "none", 60)
    c.expect(st is not None, f"{ap} sent the report when the brokers came back")


def t_flapping(c):
    """The primary site of home 2 flaps. After more than 3 changes in 10 min
    the AP holds the site down for the penalty, even when the site works.
    The penalty is set to 60 s for this test (default 60 s, doubles per new
    penalty up to 600 s). Client traffic is measured during the flaps."""
    settle(c)
    home = HOMES["home2"]
    ap, site = home["ap"], home["primary"]
    vm(ap, "echo '{\"penalty\":60}' > /etc/parker-as.tune")
    mon_start(home["clients"])
    t0 = time.time()
    try:
        for n in range(2):
            set_site_links(site, "down")
            st = wait_status(ap, lambda s: s["sites"][site]["state"] == "down", FAILOVER_TIMEOUT)
            c.expect(st is not None, f"flap {n + 1}: {site} down")
            set_site_links(site, "up")
            if n == 0:
                st = wait_status(ap, lambda s: s["sites"][site]["state"] == "up", RECOVERY_TIMEOUT)
                c.expect(st is not None, f"flap {n + 1}: {site} up")
        st = wait_status(ap, lambda s: s["sites"][site].get("penalty") == "true", RECOVERY_TIMEOUT)
        c.expect(st is not None, f"{ap} holds {site} down with a penalty: {(st or ap_status(ap))['raw']}")
        tp = time.time()
        held = wait_for(lambda: ap_status(ap)["sites"][site]["state"] == "up", 45, step=2)
        c.expect(not held, f"{site} stays down for 45 s while its pgws work")
        c.expect(ap_status(ap).get("active") == OTHER[site], f"{ap} stays on {OTHER[site]}")
        st = wait_status(ap, lambda s: all_up(s, site), RECOVERY_TIMEOUT)
        hold = round(time.time() - tp, 1)
        ap_metric(c, "penalty_hold_s", hold if st else None)
        c.expect(st is not None and hold < 60 + 30, f"{ap} back on {site} {hold} s after the penalty started")
        time.sleep(10)
        result = mon_stop(c, "flapping", home["clients"], t0)
        expect_traffic(c, "flapping", result)
    finally:
        vm(ap, "rm -f /etc/parker-as.tune")
        set_site_links(site, "up")


def t_roam(c):
    """client-1 roams from AP-1 to AP-3 (both meshed in home 1). It gets the
    prefixes of AP-3. A packet with its old AP-1 source gets ICMPv6 code 5
    from AP-3, so the client does not wait for a time-out."""
    cl, port = "client-1", "client1"
    old = client_addrs(cl)
    c.log(f"{cl} on ap-1: {old}")
    ap3 = ap_status("ap-3")
    c.log(f"ap-3 status: {ap3['raw']}")
    dx(cl, "ip link set lan down")
    run(["sudo", "ip", "link", "set", port, "nomaster"])
    run(["sudo", "ip", "link", "set", port, "master", "as-ap3-lan"])
    dx(cl, "ip link set lan up")
    try:
        def on_ap3():
            a = client_addrs(cl)
            return all(s in a and ipaddress.ip_address(a[s][0]) in ipaddress.ip_network(ap3["sites"][s]["range6"])
                       for s in ("muc", "vie")) and preferred(a, "muc")
        c.expect(wait_for(on_ap3, 120, step=5), f"{cl} has the ap-3 prefixes: {client_addrs(cl)}")
        ok, out = ping(cl, TARGET6)
        c.expect(ok, f"{cl} ping6 through ap-3: {last(out)}")
        ok, out = ping(cl, TARGET4)
        c.expect(ok, f"{cl} ping IPv4 through ap-3: {last(out)}")
        if old.get("muc"):
            addr = old["muc"][0]
            dx(cl, f"ip -6 addr add {addr}/128 dev lan nodad preferred_lft 0")
            code5_from(c, cl, addr)
            dx(cl, f"ip -6 addr del {addr}/128 dev lan")
    finally:
        dx(cl, "ip link set lan down")
        run(["sudo", "ip", "link", "set", port, "nomaster"])
        run(["sudo", "ip", "link", "set", port, "master", "as-ap1-lan"])
        dx(cl, "ip link set lan up")
        ok = wait_for(lambda: set(client_addrs(cl)) == {"muc", "vie"}, 120, step=5)
        c.log(f"{cl} back on ap-1: {client_addrs(cl)} ({ok})")


def t_old_firmware(c):
    """AP-4 has the stock firmware (no caps=multiprefix). The broker gives it
    one site. Its client has one prefix, and IPv6 and IPv4 work."""
    ap, cl = OLD["ap"], OLD["clients"][0]
    _, out = vm(ap, "grep -c caps=multiprefix /usr/sbin/nodeconfig.sh; ls /tmp/parker-as 2>&1 | head -1")
    c.log(f"{ap}: {' | '.join(out.strip().splitlines())}")
    _, out = vm(ap, "cat /tmp/ff-Ohb0ba0u/noderoute.json")
    c.expect('"sites"' not in out and '"primary_site"' not in out, f"{ap} config has no multi-site fields")
    a = client_addrs(cl)
    c.expect(set(a) == {OLD["site"]}, f"{cl} has one prefix of {OLD['site']}: {a}")
    ok, out = ping(cl, TARGET6)
    c.expect(ok, f"{cl} ping6: {last(out)}")
    ok, out = ping(cl, TARGET4)
    c.expect(ok, f"{cl} ping IPv4: {last(out)}")
    src, raw = seen_source(cl, TARGET6)
    c.expect(site_of(src) == OLD["site"], f"internet sees {cl} from {src}")


def t_pmtu(c):
    """DF/PMTU through the tunnel of each site: a large DF packet gets a
    'too big' with an MTU, and a packet of that MTU goes through."""
    for home in HOMES.values():
        cl = home["clients"][0]
        for site, (addr, _) in sorted(client_addrs(cl).items()):
            ok, mtu, out = pmtu_ping(cl, TARGET6, addr, 1452)
            if ok:
                c.log(f"{cl} {site}: 1500 byte DF ping goes through")
                continue
            ok, mtu, out = pmtu_ping(cl, TARGET6, addr, 1452)
            c.expect(mtu is not None and mtu < 1500, f"{cl} {site} from {addr}: PMTU {mtu} ({last(out)})")
            if mtu:
                ok, _, out = pmtu_ping(cl, TARGET6, addr, mtu - 48)
                c.expect(ok, f"{cl} {site}: DF ping of {mtu} bytes goes through: {last(out)}")
        ok, mtu, out = pmtu_ping(cl, TARGET4, None, 1472)
        if not ok:
            ok, mtu, out = pmtu_ping(cl, TARGET4, None, 1472)
        c.expect(ok or (mtu is not None and mtu < 1500),
                 f"{cl} IPv4 DF 1500 through the CLAT: {'ok' if ok else f'frag needed, mtu {mtu}'}")
        if not ok and mtu:
            ok, _, out = pmtu_ping(cl, TARGET4, None, mtu - 28)
            c.expect(ok, f"{cl} IPv4 DF ping of {mtu} bytes goes through: {last(out)}")


TESTS = [
    ("ready", t_ready),
    ("normal", t_normal),
    ("ra-single", t_ra_single),
    ("source-prefix", t_source_prefix),
    ("inbound-standby", t_inbound_standby),
    ("pmtu", t_pmtu),
    ("old-firmware", t_old_firmware),
    ("roam", t_roam),
    ("plane", t_plane),
    ("pgw-failure", lambda c: t_pgw_failure(c, "home2")),
    ("pgw-failure-home1", lambda c: t_pgw_failure(c, "home1")),
    ("plane-broker-down", lambda c: t_plane_failure(c, "broker-muc-1")),
    ("plane-emqx-down", lambda c: t_plane_failure(c, "emqx-muc-1")),
    ("plane-haproxy-down", lambda c: t_plane_failure(c, "lb-muc")),
    ("broker-down-pgw", t_broker_down_pgw),
    ("site-failure-vie", lambda c: t_site_failure(c, "vie")),
    ("recovery-vie", lambda c: t_recovery(c, "vie")),
    ("site-failure-long-muc", lambda c: t_site_failure(c, "muc", long_outage=True)),
    ("recovery-long-muc", lambda c: t_recovery(c, "muc")),
    ("flapping", t_flapping),
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
    global RESULTS
    RESULTS = args.results
    mon_server()

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
            json.dump({"name": name, "pass": c.ok, "evidence": c.evidence, "metrics": c.metrics}, f, indent=2)
        print(f"== {name}: {'PASS' if c.ok else 'FAIL'}", flush=True)
        all_ok = all_ok and c.ok
    for site in SITES:  # leave the links up whatever happened
        set_site_links(site, "up")
    for ctr in list(PLANE["brokers"]) + PLANE["emqx"] + PLANE["lbs"]:
        set_plane(ctr, "up")
    mon_server(start=False)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
