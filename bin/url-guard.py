#!/usr/bin/env python3
"""Resolve a URL's host and say what kind of address it landed on.

localfetch.sh reaches destinations the harness's own web tool cannot: the
LAN, the router, a service on localhost. That reach is the whole point of
the tool and also the reason it is dangerous — once granted, it is a
standing SSRF primitive available to whatever ends up in the agent's
context, including the text of a page it just read.

So every hop is resolved here, before the request, and classified. The
caller pins the exact address it was given (curl --resolve), which closes
the DNS-rebinding window between this check and the fetch, and re-runs this
for each redirect rather than letting curl follow one blindly.

  url-guard.py check <url>        -> "host\tport\tip\tclass" (exit 0)
  url-guard.py join <base> <loc>  -> absolute URL for a Location header

class is one of: public, loopback, private, link-local, metadata,
cgnat, reserved, multicast.
"""
import ipaddress
import socket
import sys
from urllib.parse import urljoin, urlsplit

# Anything in here is only reachable because this machine is where it is —
# which is exactly what an injected instruction would want to exploit.
CLOUD_METADATA = {
    ipaddress.ip_address("169.254.169.254"),   # AWS/GCP/Azure/DO
    ipaddress.ip_address("fd00:ec2::254"),     # AWS IMDSv6
}


def classify(ip: ipaddress._BaseAddress) -> str:
    if ip in CLOUD_METADATA:
        return "metadata"
    if ip.is_loopback:
        return "loopback"
    if ip.is_link_local:
        return "link-local"
    if ip.is_multicast:
        return "multicast"
    if ip.version == 4 and ip in ipaddress.ip_network("100.64.0.0/10"):
        return "cgnat"
    if ip.is_private:
        return "private"
    if ip.is_reserved or ip.is_unspecified:
        return "reserved"
    return "public"


def check(url: str) -> int:
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        print("url-guard: only http and https are supported", file=sys.stderr)
        return 2
    host = parts.hostname
    if not host:
        print("url-guard: no host in URL", file=sys.stderr)
        return 2
    try:
        port = parts.port or (443 if parts.scheme == "https" else 80)
    except ValueError:
        print("url-guard: bad port", file=sys.stderr)
        return 2

    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except OSError as exc:
        print(f"url-guard: cannot resolve {host}: {exc}", file=sys.stderr)
        return 3

    # Every answer is reported, not just the first: a name that resolves to
    # one public and one loopback address is a rebinding attempt, and the
    # caller should treat the whole destination as private.
    seen, rows = set(), []
    for info in infos:
        addr = info[4][0]
        if addr in seen:
            continue
        seen.add(addr)
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            continue
        rows.append((addr, classify(ip)))

    if not rows:
        print(f"url-guard: no usable address for {host}", file=sys.stderr)
        return 3

    # Least-public answer first, so the caller sees the worst case on line 1.
    order = ["metadata", "loopback", "link-local", "reserved", "multicast",
             "cgnat", "private", "public"]
    rows.sort(key=lambda r: order.index(r[1]) if r[1] in order else 0)
    for addr, kind in rows:
        print(f"{host}\t{port}\t{addr}\t{kind}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "check":
        return check(argv[2])
    if len(argv) >= 4 and argv[1] == "join":
        joined = urljoin(argv[2], argv[3])
        if urlsplit(joined).scheme not in ("http", "https"):
            print("url-guard: redirect leaves http(s)", file=sys.stderr)
            return 2
        print(joined)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
