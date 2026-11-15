#!/usr/bin/env python3
"""Reads the files of outage-client.sh and prints what one client saw.

Usage: outage.py <dir> <event-epoch>

The result is JSON. All times are in ms:
  ping6a, ping6b, ping4: max_gap_ms (the longest time with no reply), lost,
                sent. ping6a and ping6b use the site A and the site B source.
  tcp6, tcp4:   source (the address the server saw), survived (the stream was open at the stop), max_gap_ms
                (the longest time with no data), closed_at_ms (after the
                event, when the stream closed).
  curl6, curl4: new_conn_ms (from the event until a new connection that
                starts after the last failed one works; 0 if no attempt
                failed), failed, slowest_ms (the slowest good attempt).
"""
import ipaddress
import json
import os
import re
import sys

PING = re.compile(r"^\[(\d+\.\d+)\] \d+ bytes from .*icmp_seq=(\d+)")
NOANSWER = re.compile(r"no answer yet for icmp_seq=(\d+)")
SEQ = re.compile(r"icmp_seq=(\d+)")


def read(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except OSError:
        return None


def max_gap(times, start, stop):
    """The longest time with no data. The probes need some time to start, so
    the count starts at the first reply, if there is one."""
    times = sorted(t for t in times if start <= t <= stop)
    marks = (times or [start]) + [stop]
    return round(max(b - a for a, b in zip(marks, marks[1:])) * 1000)


def ping(lines, start, stop):
    if lines is None:
        return None
    replies, seqs = {}, set()
    for line in lines:
        m = PING.match(line)
        if m:
            replies.setdefault(int(m.group(2)), float(m.group(1)))
        m = SEQ.search(line)
        if m:
            seqs.add(int(m.group(1)))
    sent = max(seqs) if seqs else 0
    return {
        "max_gap_ms": max_gap(replies.values(), start, stop),
        "lost": len([s for s in range(1, sent + 1) if s not in replies]),
        "sent": sent,
    }


def address(text):
    try:
        return str(ipaddress.ip_address(text.strip("[]")))
    except (AttributeError, ValueError):
        return text


def tcp(lines, src, state, err, start, stop, event):
    if lines is None:
        return None
    times = [float(x) for x in lines if x]
    first = (state or [""])[0].split()
    survived = first[:1] == ["open"] and bool(times)
    closed = None
    if first[:1] == ["closed"]:
        closed = round((float(first[1]) - event) * 1000)
    return {
        "source": address((src or [None])[0]),
        "survived": survived,
        "max_gap_ms": max_gap(times, start, stop) if times else None,
        "closed_at_ms": closed,
        "error": " ".join(x for x in err or [] if "exiting on signal" not in x)[-200:] or None,
    }


def curl(lines, event):
    if lines is None:
        return None
    tries = sorted((float(t), r, float(e)) for t, r, e in (x.split() for x in lines if x))
    after = [x for x in tries if x[2] >= event]
    slowest = max([round((e - t) * 1000) for t, r, e in after if r == "ok"], default=None)
    failed = [t for t, r, e in after if r == "fail"]
    if not failed:
        return {"new_conn_ms": 0, "failed": 0, "slowest_ms": slowest}
    ok = [e for t, r, e in after if r == "ok" and t > failed[-1]]
    return {
        "new_conn_ms": round((min(ok) - event) * 1000) if ok else None,
        "failed": len(failed),
        "slowest_ms": slowest,
    }


def main():
    d, event = sys.argv[1], float(sys.argv[2])
    start = float(read(os.path.join(d, "start"))[0])
    stop = float(read(os.path.join(d, "stop"))[0])
    out = {}
    for name in ("ping6", "ping6a", "ping6b", "ping4"):
        p = ping(read(os.path.join(d, name)), start, stop)
        if p is not None:
            out[name] = p
    for v in ("6", "4"):
        t = tcp(read(os.path.join(d, "tcp" + v)), read(os.path.join(d, "tcp%s.src" % v)),
                read(os.path.join(d, "tcp%s.state" % v)),
                read(os.path.join(d, "tcp%s.err" % v)), start, stop, event)
        if t is not None:
            out["tcp" + v] = t
        c = curl(read(os.path.join(d, "curl" + v)), event)
        if c is not None:
            out["curl" + v] = c
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
