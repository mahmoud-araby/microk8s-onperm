# -*- coding: utf-8 -*-
"""Small, dependency-free network helpers used by preflight checks.

Avoids pulling in ansible.utils/netaddr just to compare a few addresses.

  "10.10.20.15" | ip_in_range("10.10.20.10-10.10.20.50")   -> True
  "10.10.20.15" | ip_in_range("10.10.20.0/24")              -> True
  "10.10.20.10-10.10.20.50" | ip_ranges_overlap("10.10.20.40-10.10.20.60") -> True
  "10.10.20.10-10.10.20.50" | ip_range_size                 -> 41
"""

from __future__ import absolute_import, division, print_function

__metaclass__ = type

import ipaddress

from ansible.errors import AnsibleFilterError


def _bounds(spec):
    """Return (first, last) integer bounds of 'a-b', CIDR or single IP."""
    spec = str(spec).strip()
    try:
        if "-" in spec:
            start, end = [s.strip() for s in spec.split("-", 1)]
            first = int(ipaddress.ip_address(start))
            last = int(ipaddress.ip_address(end))
        elif "/" in spec:
            net = ipaddress.ip_network(spec, strict=False)
            first, last = int(net.network_address), int(net.broadcast_address)
        else:
            first = last = int(ipaddress.ip_address(spec))
    except ValueError as exc:
        raise AnsibleFilterError("invalid IP range %r: %s" % (spec, exc))
    if last < first:
        raise AnsibleFilterError("invalid IP range %r: end before start" % spec)
    return first, last


def ip_in_range(ip, spec):
    first, last = _bounds(spec)
    value, _ = _bounds(ip)
    return first <= value <= last


def ip_ranges_overlap(spec_a, spec_b):
    a1, a2 = _bounds(spec_a)
    b1, b2 = _bounds(spec_b)
    return a1 <= b2 and b1 <= a2


def ip_range_size(spec):
    first, last = _bounds(spec)
    return last - first + 1


def ip_nth_in_cidr(cidr, index):
    """Return the n-th address of a CIDR (e.g. the kube-dns ClusterIP = .10)."""
    net = ipaddress.ip_network(str(cidr), strict=False)
    return str(net.network_address + int(index))


class FilterModule(object):
    def filters(self):
        return {
            "ip_in_range": ip_in_range,
            "ip_ranges_overlap": ip_ranges_overlap,
            "ip_range_size": ip_range_size,
            "ip_nth_in_cidr": ip_nth_in_cidr,
        }
